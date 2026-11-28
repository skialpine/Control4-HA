-- Independently authored suite entry point.
require("ha.device-driver").install("media_player", require("ha.media-player-adapter").new)
