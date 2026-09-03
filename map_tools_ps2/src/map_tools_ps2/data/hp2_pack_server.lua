-- Public, read-only metadata API. Files are opened by their owning pack.
local manifest, routes = false, {}
local function read(path)
    local file = fileOpen(path, true)
    if not file then return false end
    local data = fileRead(file, fileGetSize(file)); fileClose(file)
    return data
end
function getHP2TrackManifest()
    if not manifest then
        local data = read("track_manifest.json")
        manifest = data and fromJSON(data) or false
    end
    return manifest
end
function getHP2RouteText(id)
    local catalog = getHP2TrackManifest()
    local track = catalog and (catalog.tracks[tostring(tonumber(id))] or catalog.tracks[tonumber(id)])
    if not track then return false, "track is not in this pack" end
    if not routes[track.id] then routes[track.id] = read(track.routeFile) end
    return routes[track.id]
end
