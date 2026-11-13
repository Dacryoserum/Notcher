// Isolated bridge to macOS MediaRemote. Private API: failure is reported to the app.
// No browser injection, accessibility scraping, or network access.
ObjC.import('Foundation');

function finite(value, fallback) {
    var number = Number(value);
    return isFinite(number) && number >= 0 ? number : (fallback || 0);
}

function run(argv) {
    // Spotify explicitly exposes a cover URL; its deprecated artwork property is always empty.
    // Check running first so a metadata poll never launches the application.
    if (argv[0] === 'spotify-artwork') {
        try {
            var spotify = Application('com.spotify.client');
            if (!spotify.running()) return 'null';
            var track = spotify.currentTrack;
            var identity = track.id();
            var cover = {title: track.name(), artist: track.artist(), album: track.album(), url: track.artworkUrl()};
            if (identity !== spotify.currentTrack.id()) return 'null';
            return JSON.stringify(cover);
        } catch (_) { return 'null'; }
    }
    if (argv[0] === 'spotify-state' || argv[0] === 'spotify-command') {
        try {
            var player = Application('com.spotify.client');
            if (!player.running()) return 'null';
            if (argv[0] === 'spotify-command') {
                switch (argv[1]) {
                    case 'play': player.play(); break;
                    case 'pause': player.pause(); break;
                    case 'next': player.nextTrack(); break;
                    case 'previous': player.previousTrack(); break;
                    case 'seek':
                        var position = Number(argv[2]);
                        if (!isFinite(position) || position < 0) return JSON.stringify({error: 'Position invalide'});
                        player.playerPosition = position;
                        break;
                    default: return JSON.stringify({error: 'Commande inconnue'});
                }
                return JSON.stringify({sent: true});
            }
            var song = player.currentTrack;
            var id = song.id();
            // The cover address is read with the track itself, so both always describe the same song.
            var cover = null;
            try { cover = song.artworkUrl(); } catch (_) {}
            var state = {
                title: String(song.name() || ''), artist: String(song.artist() || ''), album: String(song.album() || ''),
                application: 'Spotify', bundleIdentifier: 'com.spotify.client',
                playing: String(player.playerState()).toLowerCase() === 'playing',
                duration: finite(song.duration()) / 1000,
                elapsed: finite(player.playerPosition()), artwork: null,
                artworkURL: (typeof cover === 'string' && cover.indexOf('https://') === 0) ? cover : null
            };
            if (!state.title || id !== player.currentTrack.id()) return 'null';
            return JSON.stringify(state);
        } catch (error) { return JSON.stringify({error: String(error)}); }
    }
    var framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
    if (!framework || !framework.load) return JSON.stringify({error: 'MediaRemote indisponible'});
    function unwrap(value) {
        try { return ObjC.unwrap(value); } catch (_) { return null; }
    }
    var Request = $.NSClassFromString('MRNowPlayingRequest');
    if (!Request) return JSON.stringify({error: 'Lecture système indisponible'});
    if (argv.length && argv[0] !== 'read') {
        var controls = {toggle: 2, next: 4, previous: 5, play: 0, pause: 1, seek: 24};
        var code = controls[argv[0]];
        if (typeof code !== 'number') return JSON.stringify({error: 'Commande inconnue'});
        var options = $.NSMutableDictionary.alloc.init;
        if (argv[0] === 'seek') {
            var position = Number(argv[1]);
            if (!isFinite(position) || position < 0) return JSON.stringify({error: 'Position invalide'});
            options.setObjectForKey($(position), $('kMRMediaRemoteOptionPlaybackPosition'));
        }
        var controller = $.NSClassFromString('MRNowPlayingController').localRouteController;
        controller.sendCommandOptionsCompletion(code, options, null);
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.15));
        return JSON.stringify({sent: true});
    }
    try {
        var item = Request.localNowPlayingItem;
        if (!item || !ObjC.unwrap(item)) return 'null';
        var info = item.nowPlayingInfo;
        if (!info || !ObjC.unwrap(info)) return 'null';
        function get(key) { return unwrap(info.objectForKey('kMRMediaRemoteNowPlayingInfo' + key)); }
        var title = get('Title');
        if (!title) return 'null';
        var application = '', bundleIdentifier = '';
        try {
            var client = Request.localNowPlayingPlayerPath.client;
            application = unwrap(client.displayName) || '';
            try { bundleIdentifier = unwrap(client.bundleIdentifier) || ''; } catch (_) {}
        } catch (_) {}
        var elapsed = get('ElapsedTime') || 0;
        try { elapsed = Number(item.metadata.calculatedPlaybackPosition); } catch (_) {}
        var artwork = null;
        try {
            var image = info.objectForKey('kMRMediaRemoteNowPlayingInfoArtworkData');
            if (image && Number(image.length) < 1500000) artwork = unwrap(image.base64EncodedStringWithOptions(0));
        } catch (_) {}
        return JSON.stringify({
            title: String(title), artist: String(get('Artist') || ''), album: String(get('Album') || ''),
            application: String(application), bundleIdentifier: String(bundleIdentifier),
            playing: Number(get('PlaybackRate')) > 0, duration: finite(get('Duration')),
            elapsed: finite(elapsed), artwork: artwork
        });
    } catch (error) { return JSON.stringify({error: String(error)}); }
}
