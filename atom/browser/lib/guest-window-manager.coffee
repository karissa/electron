{ipcMain, BrowserWindow} = require 'electron'
v8Util = process.atomBinding 'v8_util'

frameToGuest = {}

# Copy attribute of |parent| to |child| if it is not defined in |child|.
mergeOptions = (child, parent) ->
  for own key, value of parent when key not of child
    if typeof value is 'object'
      child[key] = mergeOptions {}, value
    else
      child[key] = value
  child

# Merge |options| with the |embedder|'s window's options.
mergeBrowserWindowOptions = (embedder, options) ->
  if embedder.browserWindowOptions?
    # Inherit the original options if it is a BrowserWindow.
    mergeOptions options, embedder.browserWindowOptions
  else
    # Or only inherit web-preferences if it is a webview.
    options.webPreferences ?= {}
    mergeOptions options.webPreferences, embedder.getWebPreferences()
  options

# Create a new guest created by |embedder| with |options|.
createGuest = (embedder, url, frameName, options) ->
  guest = frameToGuest[frameName]
  if frameName and guest?
    guest.loadURL url
    return guest.id

  guest = new BrowserWindow(options)
  guest.loadURL url

  # Remember the embedder, will be used by window.opener methods.
  v8Util.setHiddenValue guest.webContents, 'embedder', embedder

  # When |embedder| is destroyed we should also destroy attached guest, and if
  # guest is closed by user then we should prevent |embedder| from double
  # closing guest.
  guestId = guest.id
  closedByEmbedder = ->
    guest.removeListener 'closed', closedByUser
    guest.destroy()
  closedByUser = ->
    embedder.send "ATOM_SHELL_GUEST_WINDOW_MANAGER_WINDOW_CLOSED_#{guestId}"
    embedder.removeListener 'render-view-deleted', closedByEmbedder
  embedder.once 'render-view-deleted', closedByEmbedder
  guest.once 'closed', closedByUser

  if frameName
    frameToGuest[frameName] = guest
    guest.frameName = frameName
    guest.once 'closed', ->
      delete frameToGuest[frameName]

  guest.id

# Routed window.open messages.
ipcMain.on 'ATOM_SHELL_GUEST_WINDOW_MANAGER_WINDOW_OPEN', (event, args...) ->
  [url, frameName, options] = args
  options = mergeBrowserWindowOptions event.sender, options
  event.sender.emit 'new-window', event, url, frameName, 'new-window', options
  if (event.sender.isGuest() and not event.sender.allowPopups) or event.defaultPrevented
    event.returnValue = null
  else
    event.returnValue = createGuest event.sender, url, frameName, options

ipcMain.on 'ATOM_SHELL_GUEST_WINDOW_MANAGER_WINDOW_CLOSE', (event, guestId) ->
  BrowserWindow.fromId(guestId)?.destroy()

ipcMain.on 'ATOM_SHELL_GUEST_WINDOW_MANAGER_WINDOW_METHOD', (event, guestId, method, args...) ->
  BrowserWindow.fromId(guestId)?[method] args...

ipcMain.on 'ATOM_SHELL_GUEST_WINDOW_MANAGER_WINDOW_POSTMESSAGE', (event, guestId, message, targetOrigin) ->
  guestContents = BrowserWindow.fromId(guestId)?.webContents
  if guestContents?.getURL().indexOf(targetOrigin) is 0 or targetOrigin is '*'
    guestContents.send 'ATOM_SHELL_GUEST_WINDOW_POSTMESSAGE', guestId, message, targetOrigin

ipcMain.on 'ATOM_SHELL_GUEST_WINDOW_MANAGER_WINDOW_OPENER_POSTMESSAGE', (event, guestId, message, targetOrigin, sourceOrigin) ->
  embedder = v8Util.getHiddenValue event.sender, 'embedder'
  if embedder?.getURL().indexOf(targetOrigin) is 0 or targetOrigin is '*'
    embedder.send 'ATOM_SHELL_GUEST_WINDOW_POSTMESSAGE', guestId, message, sourceOrigin

ipcMain.on 'ATOM_SHELL_GUEST_WINDOW_MANAGER_WEB_CONTENTS_METHOD', (event, guestId, method, args...) ->
  BrowserWindow.fromId(guestId)?.webContents?[method] args...

ipcMain.on 'ATOM_SHELL_GUEST_WINDOW_MANAGER_GET_GUEST_ID', (event) ->
  embedder = v8Util.getHiddenValue event.sender, 'embedder'
  if embedder?
    guest = BrowserWindow.fromWebContents event.sender
    if guest?
      event.returnValue = guest.id
      return
  event.returnValue = null
