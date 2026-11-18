import QtQuick
import QtCore

// Task list model plus the file storage engine.
//
// Storage rules (data-loss safety):
// - Every read goes through _readCmd(), which reports MISSING / NODIR /
//   UNREADABLE / EMPTY / OK so a failed read is never mistaken for "no tasks".
// - Every JSON write is serialized (one at a time), chunked (no argv limit),
//   and compare-and-swap: the write is refused with CONFLICT if the file's
//   "mtime size" signature is not the one we last read or wrote. A conflict
//   triggers a re-read and merge, then a new write.
// - The previous file is kept as <path>.bak, and timestamped snapshots are
//   kept for destructive merges and for the first write of each session.
// - Deletions travel between machines as tombstones in the file's "deleted"
//   array; a local task is only removed when the file carries a tombstone that
//   is at least as new as the task, and only on live sync reads.
// - The widget-settings copy (cfg.tasksJson) is updated on every save, so a
//   failed file write never loses the change.
ListModel {
    id: model

    // Injected configuration object (Plasmoid.configuration in the widget, a
    // plain QtObject in tests).
    property var cfg: null

    // Non-empty when the tasks file cannot be read or written. One of
    // "unreadable", "nodir", "corrupt", "write", "conflict".
    property string storageError: ""

    property bool _started: false
    property string _path: ""
    property bool _loaded: false
    property bool _writeBusy: false
    property bool _writeDirty: false
    property bool _writeBlocked: false
    property string _intent: ""
    property string _fileSig: ""
    property string _tmpToken: ""
    property int _cmdSeq: 0
    property var _job: null
    property int _jobIdx: 0
    property bool _exportsPending: false
    property bool _readInFlight: false
    property bool _readWanted: false
    property string _readTarget: "main"
    property string _readBase: ""
    property string _lastReadCmd: ""
    property string _bakMode: ""
    property bool _initialLoad: true
    property bool _noDeleteNextLoad: false
    property bool _sessionSnapshotDone: false
    property int _conflictRetries: 0
    property int _conflictCount: 0
    property var _sampleUuids: ({})
    property bool _pendingSamples: false
    property bool _samplesRefused: false
    property var _tombs: ({})

    readonly property int _chunkSize: 60000
    readonly property int _maxConflictRetries: 3
    readonly property int _tombstoneDays: 30

    signal runShellCmd(string cmd)
    signal requestFileLoad(string path)
    signal modelReloaded()

    function newUuid() {
        var s = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        return s.replace(/[xy]/g, function(c) {
            var r = Math.floor(Math.random() * 16)
            var v = (c === "x") ? r : ((r & 0x3) | 0x8)
            return v.toString(16)
        })
    }

    function _randomHex(n) {
        var s = ""
        for (var i = 0; i < n; i++)
            s += Math.floor(Math.random() * 16).toString(16)
        return s
    }

    function _base64Bytes(bytes) {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        var out = []
        for (var j = 0; j < bytes.length; j += 3) {
            var b0 = bytes[j]
            var b1 = j + 1 < bytes.length ? bytes[j + 1] : 0
            var b2 = j + 2 < bytes.length ? bytes[j + 2] : 0
            out.push(chars[b0 >> 2] +
                     chars[((b0 & 3) << 4) | (b1 >> 4)] +
                     (j + 1 < bytes.length ? chars[((b1 & 15) << 2) | (b2 >> 6)] : "=") +
                     (j + 2 < bytes.length ? chars[b2 & 63] : "="))
        }
        return out.join("")
    }

    // Base64 of the UTF-8 bytes of a string, done natively where Qt allows,
    // since the JS encoder above takes ~160 ms for a 250 KB list on the
    // shell's UI thread (the native paths ~25 ms):
    //   "buffer"  Qt 6.12+: Qt.btoa(ArrayBuffer). Qt.btoa(string) is
    //             deprecated there and logs a warning on use.
    //   "string"  older Qt: Qt.btoa(string), which encodes UTF-8.
    //   "js"      neither behaves as expected: the JS encoder.
    readonly property string _base64Mode: _detectBase64Mode()

    function _detectBase64Mode() {
        try {
            if (String(Qt.btoa(new Uint8Array([0xC3, 0xA9]).buffer)) === "w6k=")
                return "buffer"
        } catch (e) { }
        try {
            if (Qt.btoa("\u00e9\u2713\ud83d\ude80") === "w6ninJPwn5qA")
                return "string"
        } catch (e) { }
        return "js"
    }

    function _utf8Buffer(str) {
        var bin
        try {
            bin = unescape(encodeURIComponent(str))     // one char per UTF-8 byte
        } catch (e) {
            return new Uint8Array(_toUtf8Bytes(str)).buffer   // lone surrogates
        }
        var u = new Uint8Array(bin.length)
        for (var i = 0; i < bin.length; i++)
            u[i] = bin.charCodeAt(i)
        return u.buffer
    }

    function _base64(str) {
        if (_base64Mode === "buffer")
            return String(Qt.btoa(_utf8Buffer(str)))
        if (_base64Mode === "string")
            return Qt.btoa(str)
        return _base64Bytes(_toUtf8Bytes(str))
    }

    // Number of bytes a padded base64 string decodes to.
    function _base64Length(b64) {
        var pad = b64.endsWith("==") ? 2 : (b64.endsWith("=") ? 1 : 0)
        return b64.length / 4 * 3 - pad
    }

    function _shellArg(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    function _dirOf(path) {
        var lastSlash = path.lastIndexOf("/")
        if (lastSlash === -1) return "."
        if (lastSlash === 0) return "/"
        return path.substring(0, lastSlash)
    }

    function _normalizePath(p) {
        var v = (p === undefined || p === null) ? "" : String(p).trim()
        if (v.startsWith("file://")) {
            v = v.substring(7)
            try { v = decodeURIComponent(v) } catch (e) { }
        }
        return v
    }

    function _defaultPath() {
        var dataHome = _normalizePath(StandardPaths.writableLocation(StandardPaths.GenericDataLocation).toString())
        return dataHome + "/kdoit/tasks.json"
    }

    function touch(index) {
        if (index >= 0 && index < count)
            setProperty(index, "modifiedAt", new Date().toISOString())
    }

    // ListModel fixes each role's type on first insert and drops values of any
    // other type, so every field is coerced to the type the model expects.
    function _str(v) {
        return (v === undefined || v === null) ? "" : String(v)
    }

    function _priority(v) {
        if (v === undefined || v === null) return 1
        var n = Math.round(Number(v))
        return isNaN(n) ? 1 : Math.max(0, Math.min(2, n))
    }

    function _isObject(x) {
        return x !== null && typeof x === "object"
    }

    function normalizeTask(t) {
        var uuid = _str(t.uuid)
        return {
            uuid: uuid !== "" ? uuid : newUuid(),
            title: _str(t.title),
            done: t.done === true,
            priority: _priority(t.priority),
            category: _str(t.category).trim(),
            createdAt: t.createdAt != null ? String(t.createdAt) : new Date().toISOString(),
            modifiedAt: t.modifiedAt != null ? String(t.modifiedAt) : new Date().toISOString(),
            dueDate: _str(t.dueDate),
            sublist: normalizeSublist(t.sublist)
        }
    }

    function _normalizeSubItem(s) {
        var uuid = _str(s.uuid)
        return { uuid: uuid !== "" ? uuid : newUuid(), title: _str(s.title), done: s.done === true }
    }

    function normalizeSublist(sub) {
        var out = []
        if (Array.isArray(sub)) {
            for (var i = 0; i < sub.length; i++) {
                if (_isObject(sub[i]))
                    out.push(_normalizeSubItem(sub[i]))
            }
        } else if (sub && typeof sub.count === "number" && typeof sub.get === "function") {
            for (var j = 0; j < sub.count; j++)
                out.push(_normalizeSubItem(sub.get(j)))
        }
        return out
    }

    function _parseConfigJson(raw) {
        if (!raw || raw === "" || raw === "[]") return []
        try {
            var parsed = JSON.parse(raw)
            if (Array.isArray(parsed)) return parsed.filter(_isObject)
            return []
        } catch(e) { return [] }
    }

    // ---------------------------------------------------------------------
    // Tombstones
    // ---------------------------------------------------------------------

    function _pruneTombs(map) {
        var cutoff = new Date(Date.now() - _tombstoneDays * 86400000).toISOString()
        var out = {}
        for (var u in map) {
            if (map[u] && map[u] >= cutoff) out[u] = map[u]
        }
        return out
    }

    function _tombsFromArray(arr) {
        var map = {}
        if (!Array.isArray(arr)) return map
        for (var i = 0; i < arr.length; i++) {
            var t = arr[i]
            if (!t || !t.uuid || !t.deletedAt) continue
            var u = String(t.uuid), d = String(t.deletedAt)
            if (!map[u] || d > map[u]) map[u] = d
        }
        return map
    }

    function _tombsToArray() {
        var arr = []
        for (var u in _tombs) arr.push({ uuid: u, deletedAt: _tombs[u] })
        arr.sort(function(a, b) { return a.deletedAt < b.deletedAt ? -1 : (a.deletedAt > b.deletedAt ? 1 : 0) })
        return arr
    }

    function _mergeTombs(map) {
        var m = Object.assign({}, _tombs)
        var changed = false
        for (var u in map) {
            if (!m[u] || map[u] > m[u]) { m[u] = map[u]; changed = true }
        }
        _tombs = _pruneTombs(m)
        return changed
    }

    function _addTomb(uuid) {
        if (!uuid) return
        var m = Object.assign({}, _tombs)
        m[uuid] = new Date().toISOString()
        _tombs = m
    }

    function _removeTomb(uuid) {
        if (!uuid || _tombs[uuid] === undefined) return
        var m = Object.assign({}, _tombs)
        delete m[uuid]
        _tombs = m
    }

    // ---------------------------------------------------------------------
    // Shell command builders
    // ---------------------------------------------------------------------

    function _tag(kind) {
        _cmdSeq++
        return ": kdoit-" + kind + "-" + _tmpToken + "-" + _cmdSeq + "; "
    }

    // Prints one status line, then (for OK) the file content:
    //   KDOIT-STATUS:MISSING            file absent, parent dir exists
    //   KDOIT-STATUS:NODIR              parent dir absent
    //   KDOIT-STATUS:UNREADABLE         not a regular readable file
    //   KDOIT-STATUS:EMPTY <sig>        zero-length file
    //   KDOIT-STATUS:OK <sig>\n<content>
    // <sig> is `stat -L -c '%y %s'`. The content is re-read if the file
    // changes while it is being read.
    function _readCmd(path) {
        var cmd = _tag("read") + "P=" + _shellArg(path) + "; " +
            "D=$(dirname -- \"$P\"); " +
            "if [ ! -e \"$P\" ] && [ ! -L \"$P\" ]; then " +
                "if [ -d \"$D\" ] && [ -x \"$D\" ]; then echo KDOIT-STATUS:MISSING; " +
                "elif [ -e \"$D\" ]; then echo KDOIT-STATUS:UNREADABLE; " +
                "else echo KDOIT-STATUS:NODIR; fi; exit 0; fi; " +
            "if [ ! -f \"$P\" ] || [ ! -r \"$P\" ]; then echo KDOIT-STATUS:UNREADABLE; exit 0; fi; " +
            "n=0; while :; do " +
                "S1=$(stat -L -c '%y %s' -- \"$P\") || { echo KDOIT-STATUS:UNREADABLE; exit 0; }; " +
                "if [ ! -s \"$P\" ]; then echo \"KDOIT-STATUS:EMPTY $S1\"; exit 0; fi; " +
                "C=$(cat -- \"$P\" && printf x) || { echo KDOIT-STATUS:UNREADABLE; exit 0; }; " +
                "S2=$(stat -L -c '%y %s' -- \"$P\") || { echo KDOIT-STATUS:UNREADABLE; exit 0; }; " +
                "[ \"$S1\" = \"$S2\" ] && break; " +
                "n=$((n + 1)); if [ $n -ge 5 ]; then echo KDOIT-STATUS:UNREADABLE; exit 0; fi; sleep 0.2; " +
            "done; " +
            "printf 'KDOIT-STATUS:OK %s\\n%s' \"$S1\" \"${C%x}\""
        _lastReadCmd = cmd
        return cmd
    }

    // Signature used by the sync poll; same format as the read/write protocol.
    function _statCmd(path) {
        var P = _shellArg(path)
        return "if [ -e " + P + " ] || [ -L " + P + " ]; then " +
            "stat -L -c '%y %s' -- " + P + " 2>/dev/null || echo UNREADABLE; " +
            "else echo MISSING; fi"
    }

    // Builds the command sequence for one atomic file write.
    // opts: { cas, expectSig, intent, backup, snapshot }
    function _buildWriteCmds(path, content, opts) {
        var b64 = _base64(content)
        var B = path + ".tmp." + _tmpToken + ".b64"
        var cmds = []
        cmds.push(_tag("w") + "mkdir -p -- " + _shellArg(_dirOf(path)) + " && : > " + _shellArg(B))
        for (var i = 0; i < b64.length; i += _chunkSize)
            cmds.push(_tag("w") + "printf '%s' '" + b64.substring(i, i + _chunkSize) + "' >> " + _shellArg(B))
        var script = _tag("w") +
            "set -e; " +
            "P=" + _shellArg(path) + "; B=" + _shellArg(B) + "; " +
            "E=" + _shellArg(opts.expectSig || "") + "; I=" + _shellArg(opts.intent || "user") + "; " +
            "N=" + _base64Length(b64) + "; CAS=" + (opts.cas ? 1 : 0) + "; BK=" + (opts.backup ? 1 : 0) + "; " +
            "SNAP=" + (opts.snapshot ? 1 : 0) + "; TK=" + _tmpToken + "; T=; " +
            "trap 'rm -f -- \"$B\"; [ -n \"$T\" ] && rm -f -- \"$T\"; :' EXIT; " +
            "if [ -e \"$P\" ] || [ -L \"$P\" ]; then C=$(stat -L -c '%y %s' -- \"$P\" 2>/dev/null) || C=UNREADABLE; else C=MISSING; fi; " +
            "if [ \"$CAS\" = 1 ] && [ \"$C\" != \"$E\" ]; then echo KDOIT-WRITE:CONFLICT; exit 3; fi; " +
            "if [ -L \"$P\" ]; then R=$(readlink -f -- \"$P\"); else R=$P; fi; " +
            "if [ \"$I\" = defaults ] && [ -s \"$R\" ]; then echo KDOIT-WRITE:REFUSED; exit 4; fi; " +
            "T=\"$R.tmp.$TK\"; " +
            "base64 -d < \"$B\" > \"$T\"; " +
            "S=$(wc -c < \"$T\"); S=$((S + 0)); " +
            "if [ \"$S\" -ne \"$N\" ]; then echo \"KDOIT-WRITE:SHORT $S\"; exit 5; fi; " +
            "if [ \"$BK\" = 1 ] && [ -s \"$P\" ]; then " +
                "cp -p -- \"$P\" \"$P.bak\"; " +
                "if [ \"$SNAP\" = 1 ]; then " +
                    "F=\"$P.bak-$(date +%Y%m%d-%H%M%S)\"; if [ -e \"$F\" ]; then F=\"$F-$$\"; fi; " +
                    "cp -p -- \"$P\" \"$F\"; " +
                    "ls -1d -- \"$P\".bak-[0-9]* 2>/dev/null | sort -r | tail -n +11 | " +
                        "while IFS= read -r f; do rm -f -- \"$f\"; done; " +
                "fi; " +
            "fi; " +
            "sync -d \"$T\" 2>/dev/null || true; " +
            "mv -f -- \"$T\" \"$R\"; T=; " +
            "echo \"KDOIT-WRITE:OK $(stat -L -c '%y %s' -- \"$P\")\""
        cmds.push(script)
        return cmds
    }

    // ---------------------------------------------------------------------
    // Reading
    // ---------------------------------------------------------------------

    function requestRead() {
        if (_path === "") return
        if (_readInFlight || _writeBusy) {
            _readWanted = true
            return
        }
        _startRead(_path, "main")
    }

    function _startRead(path, target) {
        _readInFlight = true
        _readTarget = target
        _readBase = _path
        requestFileLoad(path)
    }

    function _parseReadResult(exitCode, stdout) {
        var out = stdout || ""
        var nl = out.indexOf("\n")
        var first = nl === -1 ? out : out.substring(0, nl)
        if (exitCode !== 0 || first.indexOf("KDOIT-STATUS:") !== 0)
            return { status: "UNREADABLE", sig: "", content: "" }
        var rest = first.substring("KDOIT-STATUS:".length)
        var sp = rest.indexOf(" ")
        var status = sp === -1 ? rest : rest.substring(0, sp)
        var sig = sp === -1 ? "" : rest.substring(sp + 1)
        var known = ["MISSING", "NODIR", "UNREADABLE", "EMPTY", "OK"]
        if (known.indexOf(status) === -1)
            return { status: "UNREADABLE", sig: "", content: "" }
        return { status: status, sig: sig, content: nl === -1 ? "" : out.substring(nl + 1) }
    }

    // Returns { tasks: [...], deleted: {uuid: deletedAt} } or null if the
    // content is not a recognised task document.
    function _parseDoc(text) {
        var doc
        try { doc = JSON.parse(text) } catch (e) { return null }
        var tasks = null, deleted = []
        if (Array.isArray(doc)) tasks = doc
        else if (doc && typeof doc === "object" && Array.isArray(doc.tasks)) {
            tasks = doc.tasks
            if (Array.isArray(doc.deleted)) deleted = doc.deleted
        }
        if (tasks === null) return null
        tasks = tasks.filter(_isObject)
        return { tasks: tasks, deleted: _tombsFromArray(deleted) }
    }

    // Called by main.qml's fileReader with the output of _readCmd().
    function loadFromShell(exitCode, stdout, cmd) {
        if (!_readInFlight) return
        if (cmd !== undefined && cmd !== _lastReadCmd) return
        _readInFlight = false
        var r = _parseReadResult(exitCode, stdout)
        try {
            if (_readBase !== _path)
                _readWanted = true          // path changed while reading
            else if (_readTarget === "bak")
                _handleBakRead(r)
            else
                _handleMainRead(r)
        } catch (e) {
            console.warn("KDoit loadFromShell:", e)
        }
        _afterIo()
    }

    function readTimeout() {
        if (!_readInFlight) return
        console.warn("KDoit: reading the tasks file timed out")
        loadFromShell(-1, "", _lastReadCmd)
    }

    function _clearReadError() {
        if (storageError === "unreadable" || storageError === "nodir" || storageError === "corrupt")
            storageError = ""
    }

    function _handleMainRead(r) {
        var initial = _initialLoad
        var noDelete = _noDeleteNextLoad
        _initialLoad = false
        _noDeleteNextLoad = false

        var st = r.status
        if (st === "NODIR" && _path === _defaultPath()) st = "MISSING"
        if (st === "OK" && r.content.trim() === "") st = "EMPTY"

        if (st === "UNREADABLE" || st === "NODIR") {
            // Never inject samples, never write; keep whatever is in memory.
            _fileSig = ""
            _writeBlocked = true
            storageError = st === "NODIR" ? "nodir" : "unreadable"
            _loaded = true
            console.warn("KDoit: tasks file", _path, "status", st, "- writes paused")
            return
        }

        if (st === "MISSING" || st === "EMPTY") {
            _fileSig = st === "MISSING" ? "MISSING" : r.sig
            _writeBlocked = false
            _clearReadError()
            if (count === 0) {
                _bakMode = "recover"
                _startRead(_path + ".bak", "bak")
                return
            }
            _loaded = true
            save("merge")
            return
        }

        // OK with content
        _fileSig = r.sig
        var parsed = _parseDoc(r.content)
        if (parsed === null) {
            console.warn("KDoit: tasks file", _path, "could not be parsed")
            if (count === 0) {
                _bakMode = "corrupt"
                _startRead(_path + ".bak", "bak")
                return
            }
            // Keep memory; the write snapshots the damaged file first.
            _writeBlocked = false
            _loaded = true
            save("destructive")
            return
        }

        _writeBlocked = false
        _loaded = true
        _clearReadError()
        _mergeTombs(parsed.deleted)
        if (_pendingSamples && parsed.tasks.length > 0)
            _dropSamples()

        if (parsed.tasks.length === 0) {
            if (count === 0) return     // nothing on either side
            if (initial || noDelete || !cfg.syncEnabled) {
                // Local wins: an empty file never wipes memory on load.
                save("merge")
                return
            }
            // Live sync read: fall through to the tombstone merge, which only
            // removes tasks the file explicitly marks as deleted.
        }

        var allowDelete = cfg.syncEnabled === true && !initial && !noDelete
        var res = _mergeIncoming(parsed.tasks, parsed.deleted, allowDelete)
        if (res.removed > 0) save("destructive")
        else if (res.changed || res.needWrite) save("merge")
        if (res.changed || res.removed > 0) modelReloaded()
    }

    function _handleBakRead(r) {
        var mode = _bakMode
        _bakMode = ""
        var parsed = null
        if (r.status === "OK") {
            parsed = _parseDoc(r.content)
            if (parsed && parsed.tasks.length === 0) parsed = null
        }
        if (parsed) {
            console.warn("KDoit: recovered", parsed.tasks.length, "tasks from", _path + ".bak")
            _mergeTombs(parsed.deleted)
            _mergeIncoming(parsed.tasks, parsed.deleted, false)
            _loaded = true
            _writeBlocked = false
            save(mode === "corrupt" ? "destructive" : "merge")
            modelReloaded()
            return
        }
        _loaded = true
        if (mode === "corrupt") {
            _writeBlocked = true
            storageError = "corrupt"
            return
        }
        _writeBlocked = false
        if (count === 0 && cfg.migratedToFile !== true && !_samplesRefused) {
            _injectSamples()
            save("defaults")
            modelReloaded()
        }
    }

    // Merges incoming tasks into the model (uuid-based, newer modifiedAt wins).
    // Local tasks are only removed when allowDelete is true and the incoming
    // document has a tombstone for them that is at least as new as the task.
    function _mergeIncoming(incoming, incomingTombs, allowDelete) {
        var changed = false, removed = 0, needWrite = false
        var currentByUuid = {}
        for (var i = 0; i < count; i++)
            currentByUuid[get(i).uuid] = i
        var seen = {}

        for (var j = 0; j < incoming.length; j++) {
            var inc = normalizeTask(incoming[j])
            // Missing modifiedAt counts as epoch so external tasks without a
            // timestamp never overwrite local edits.
            if (!incoming[j].modifiedAt) inc.modifiedAt = "1970-01-01T00:00:00.000Z"
            seen[inc.uuid] = true
            var idx = currentByUuid[inc.uuid]
            if (idx !== undefined) {
                var existing = get(idx)
                if (inc.modifiedAt > existing.modifiedAt) {
                    setProperty(idx, "title", inc.title)
                    setProperty(idx, "done", inc.done)
                    setProperty(idx, "priority", inc.priority)
                    setProperty(idx, "category", inc.category)
                    if (!existing.createdAt)
                        setProperty(idx, "createdAt", inc.createdAt)
                    setProperty(idx, "modifiedAt", inc.modifiedAt)
                    setProperty(idx, "dueDate", inc.dueDate)
                    var sub = existing.sublist
                    if (sub && typeof sub.clear === "function") {
                        sub.clear()
                        for (var k = 0; k < inc.sublist.length; k++)
                            sub.append(inc.sublist[k])
                    } else {
                        setProperty(idx, "sublist", inc.sublist)
                    }
                    changed = true
                } else if (existing.modifiedAt > inc.modifiedAt) {
                    needWrite = true
                }
            } else {
                var tomb = _tombs[inc.uuid]
                if (tomb !== undefined && tomb >= inc.modifiedAt)
                    continue            // deleted elsewhere; do not resurrect
                append(inc)
                currentByUuid[inc.uuid] = count - 1
                changed = true
            }
        }

        if (allowDelete) {
            for (var d = count - 1; d >= 0; d--) {
                var t = get(d)
                var ts = incomingTombs[t.uuid]
                if (ts !== undefined && ts >= t.modifiedAt) {
                    remove(d)
                    removed++
                }
            }
        }

        for (var n = 0; n < count; n++) {
            if (!seen[get(n).uuid]) { needWrite = true; break }
        }
        for (var u in _tombs) {
            if (incomingTombs[u] === undefined || incomingTombs[u] < _tombs[u]) { needWrite = true; break }
        }
        return { changed: changed, removed: removed, needWrite: needWrite }
    }

    // Called by main.qml's sync poll with the output of _statCmd().
    function pollResult(exitCode, stdout) {
        if (!_loaded || _readInFlight || _writeBusy || exitCode !== 0) return
        var sig = (stdout || "").trim()
        if (sig !== _fileSig) requestRead()
    }

    // Called when the configured storage path changes.
    function storagePathChanged() {
        if (!_started || !cfg) return
        var p = _normalizePath(cfg.storagePath)
        if (p === "") p = _defaultPath()
        if (p === _path) return
        _path = p
        _fileSig = ""
        _loaded = false
        _noDeleteNextLoad = true
        _writeBlocked = false
        _conflictRetries = 0
        storageError = ""
        requestRead()
    }

    // "Retry" from the error banner.
    function retryStorage() {
        _conflictRetries = 0
        requestRead()
    }

    function _injectSamples() {
        var before = count
        _addDefaultTasks()
        var m = {}
        for (var i = before; i < count; i++) m[get(i).uuid] = true
        _sampleUuids = m
        _pendingSamples = true
    }

    function _dropSamples() {
        var m = _sampleUuids
        for (var i = count - 1; i >= 0; i--) {
            if (m[get(i).uuid]) remove(i)
        }
        _sampleUuids = {}
        _pendingSamples = false
        _updateConfigCopy()
        modelReloaded()
    }

    // ---------------------------------------------------------------------
    // Writing
    // ---------------------------------------------------------------------

    function _intentRank(i) {
        return ({ "": -1, "defaults": 0, "user": 1, "merge": 2, "destructive": 3 })[i] || 0
    }

    function _maxIntent(a, b) {
        return _intentRank(a) >= _intentRank(b) ? a : b
    }

    function _tasksArray() {
        var arr = []
        for (var i = 0; i < count; i++) {
            var t = get(i)
            arr.push({
                uuid: t.uuid,
                title: t.title,
                done: t.done,
                priority: t.priority,
                category: t.category,
                createdAt: t.createdAt,
                modifiedAt: t.modifiedAt,
                dueDate: t.dueDate,
                sublist: normalizeSublist(t.sublist)
            })
        }
        return arr
    }

    function _serializeDoc() {
        _tombs = _pruneTombs(_tombs)
        return JSON.stringify({ version: 1, tasks: _tasksArray(), deleted: _tombsToArray() }, null, 2)
    }

    function _updateConfigCopy() {
        if (!cfg) return
        cfg.tasksJson = JSON.stringify(_tasksArray())
        cfg.tombstonesJson = JSON.stringify(_tombsToArray())
    }

    function _mdPath() {
        var mdPath = cfg.markdownPath ? _normalizePath(cfg.markdownPath) : ""
        if (mdPath === "") {
            mdPath = _path.replace(/\.json$/i, ".md")
            if (mdPath === _path) mdPath = _path + ".md"
        }
        return mdPath
    }

    function _icsPath() {
        var icsPath = _path.replace(/\.json$/i, ".ics")
        if (icsPath === _path) icsPath = _path + ".ics"
        return icsPath
    }

    function _pump() {
        if (!_loaded || _writeBusy || _readInFlight || _path === "") return
        if (_writeDirty && _writeBlocked) {
            // Do not write blind: re-read first. The read result unblocks.
            requestRead()
            return
        }
        if (_writeDirty) {
            if (count === 0 && _fileSig === "MISSING" && Object.keys(_tombs).length === 0) {
                // Nothing worth creating a file for.
                _writeDirty = false
                _intent = ""
            } else {
                _startJsonWrite()
                return
            }
        }
        if (_exportsPending) {
            _exportsPending = false
            _startExports()
        }
    }

    function _afterIo() {
        if (_readWanted && !_readInFlight && !_writeBusy) {
            _readWanted = false
            requestRead()
            return
        }
        if (!_writeBlocked) _pump()
    }

    function _startJsonWrite() {
        var intent = _intent || "user"
        _writeDirty = false
        _intent = ""
        var snap = intent === "destructive" || !_sessionSnapshotDone
        var cmds = _buildWriteCmds(_path, _serializeDoc(), {
            cas: true, expectSig: _fileSig, intent: intent, backup: true, snapshot: snap
        })
        _startJob({ kind: "json", path: _path, cmds: cmds, intent: intent })
    }

    function _startExports() {
        var cmds = []
        if (cfg.markdownExport) {
            var mdPath = _mdPath()
            if (mdPath !== _path)
                cmds = cmds.concat(_buildWriteCmds(mdPath, _serializeMarkdown(),
                    { cas: false, intent: "export", backup: false, snapshot: false }))
        }
        if (cfg.enableIcsExport) {
            var ics = _buildIcs()
            if (ics !== null)
                cmds = cmds.concat(_buildWriteCmds(_icsPath(), ics,
                    { cas: false, intent: "export", backup: false, snapshot: false }))
        }
        if (cmds.length > 0)
            _startJob({ kind: "export", path: _path, cmds: cmds, intent: "export" })
    }

    function _startJob(job) {
        _job = job
        _jobIdx = 0
        _writeBusy = true
        runShellCmd(job.cmds[0])
    }

    // Called by main.qml's writer DataSource for every finished command.
    function shellResult(cmd, exitCode, stdout, stderr) {
        var job = _job
        if (!job || cmd !== job.cmds[_jobIdx]) return
        if (_jobIdx < job.cmds.length - 1) {
            if (exitCode === 0) {
                _jobIdx++
                runShellCmd(job.cmds[_jobIdx])
            } else {
                _jobFailed(job, "step " + _jobIdx + " exit " + exitCode + ": " + (stderr || stdout || ""))
            }
            return
        }
        var m = /KDOIT-WRITE:([A-Z]+)(?: ([^\n]*))?/.exec(stdout || "")
        var status = m ? m[1] : ""
        _job = null
        _writeBusy = false

        if (job.kind === "export") {
            if (exitCode !== 0 || status !== "OK")
                console.warn("KDoit export failed:", stderr || stdout)
            _afterIo()
            return
        }

        if (exitCode === 0 && status === "OK") {
            if (job.path === _path) {
                _fileSig = (m[2] || "").trim()
                if (cfg.migratedToFile !== true)
                    cfg.migratedToFile = true
                storageError = ""
                _writeBlocked = false
                _conflictRetries = 0
                _pendingSamples = false
                _sampleUuids = {}
                _sessionSnapshotDone = true
                if (cfg.markdownExport || cfg.enableIcsExport)
                    _exportsPending = true
            }
            _afterIo()
            return
        }

        if (status === "CONFLICT") {
            _conflictCount++
            _writeDirty = true
            _intent = _maxIntent(_intent, job.intent)
            _conflictRetries++
            if (_conflictRetries > _maxConflictRetries) {
                storageError = "conflict"
                _writeBlocked = true
                console.warn("KDoit: tasks file keeps changing during save; giving up for now")
                return
            }
            _readWanted = true
            _afterIo()
            return
        }

        if (status === "REFUSED") {
            // The sample tasks were about to land on a non-empty file.
            _samplesRefused = true
            if (_pendingSamples) _dropSamples()
            _readWanted = true
            _afterIo()
            return
        }

        _jobFailed(job, "exit " + exitCode + ": " + (stderr || stdout || ""))
    }

    function shellTimeout() {
        if (!_job) return
        _jobFailed(_job, "timed out")
    }

    function _jobFailed(job, msg) {
        _job = null
        _writeBusy = false
        if (job.kind === "export") {
            console.warn("KDoit export failed:", msg)
            _afterIo()
            return
        }
        console.warn("KDoit save failed:", msg)
        _writeDirty = true
        _intent = _maxIntent(_intent, job.intent)
        storageError = "write"
        _writeBlocked = true
        // No automatic retry: the next save, sync poll or Retry re-reads first.
        if (_readWanted) _afterIo()
    }

    function isIdle() {
        return _loaded && !_writeBusy && !_readInFlight && !_writeDirty && !_readWanted && !_exportsPending
    }

    function _addDefaultTasks() {
        var now = new Date().toISOString()
        var today = now.substring(0, 10)
        var tomorrow = new Date(Date.now() + 86400000).toISOString().substring(0, 10)
        append(normalizeTask({
            uuid: newUuid(),
            title: "Click the subtask count to open a sublist",
            done: false,
            priority: 1,
            category: "",
            createdAt: now,
            modifiedAt: now,
            dueDate: "",
            sublist: [
                { uuid: newUuid(), title: "Tasks can nest one level deep", done: false },
                { uuid: newUuid(), title: "Right-click task to date/category/priority", done: false },
                { uuid: newUuid(), title: "Drag tasks to reorder", done: false }
            ]
        }))
        append(normalizeTask({
            uuid: newUuid(),
            title: "Right click and configure KDoit",
            done: false,
            priority: 1,
            category: "",
            createdAt: now,
            modifiedAt: now,
            dueDate: "",
            sublist: []
        }))
        append(normalizeTask({
            uuid: newUuid(),
            title: "Fix the bug that only appears on Fridays",
            done: false,
            priority: 2,
            category: "Work",
            createdAt: now,
            modifiedAt: now,
            dueDate: today,
            sublist: [
                { uuid: newUuid(), title: "Reproduce it on a Friday", done: false },
                { uuid: newUuid(), title: "Convince yourself it's the framework's fault", done: false }
            ]
        }))
        append(normalizeTask({
            uuid: newUuid(),
            title: "Reply to that email from three weeks ago",
            done: false,
            priority: 1,
            category: "Personal",
            createdAt: now,
            modifiedAt: now,
            dueDate: tomorrow,
            sublist: [
                { uuid: newUuid(), title: "Open the email", done: false },
                { uuid: newUuid(), title: "Type 'Hi'", done: false },
                { uuid: newUuid(), title: "Panic and close the tab", done: false }
            ]
        }))
        append(normalizeTask({
            uuid: newUuid(),
            title: "Exit vim",
            done: false,
            priority: 0,
            category: "Education",
            createdAt: now,
            modifiedAt: now,
            dueDate: "",
            sublist: [
                { uuid: newUuid(), title: "Try :q", done: true },
                { uuid: newUuid(), title: "Try :quit", done: true },
                { uuid: newUuid(), title: "Google 'how to exit vim'", done: false },
                { uuid: newUuid(), title: "Accept your new life here", done: false }
            ]
        }))
    }

    function load() {
        clear()
        var arr = _parseConfigJson(cfg.tasksJson)
        for (var i = 0; i < arr.length; i++)
            append(normalizeTask(arr[i]))
        var tombArr = []
        try { tombArr = JSON.parse(cfg.tombstonesJson || "[]") } catch (e) { tombArr = [] }
        _tombs = _pruneTombs(_tombsFromArray(tombArr))
        requestRead()
    }

    function _serializeMarkdown() {
        var lines = ["# Tasks", ""]
        for (var i = 0; i < count; i++) {
            var t = get(i)
            var checkbox = t.done ? "- [x]" : "- [ ]"
            var meta = []
            if (t.priority === 2) meta.push("\u23EB")
            else if (t.priority === 1) meta.push("\uD83D\uDD3C")
            else if (t.priority === 0) meta.push("\uD83D\uDD3D")
            if (t.dueDate !== "") meta.push("\uD83D\uDCC5 " + t.dueDate)
            if (t.category !== "") meta.push("#" + t.category)
            var suffix = meta.length > 0 ? " " + meta.join(" ") : ""
            var comment = " <!-- kdoit-id:" + t.uuid + " modifiedAt:" + t.modifiedAt + " -->"
            lines.push(checkbox + " " + t.title + suffix + comment)
            var sub = t.sublist
            var subCount = (sub && typeof sub.count === "number") ? sub.count : (sub ? sub.length || 0 : 0)
            for (var j = 0; j < subCount; j++) {
                var s = (sub && typeof sub.get === "function") ? sub.get(j) : sub[j]
                var subCheck = s.done ? "- [x]" : "- [ ]"
                var subComment = s.uuid ? " <!-- kdoit-id:" + s.uuid + " -->" : ""
                lines.push("  " + subCheck + " " + s.title + subComment)
            }
        }
        lines.push("")
        return lines.join("\n")
    }

    // --- iCal export helpers (RFC 5545) ---

    function _toUtf8Bytes(str) {
        var bytes = []
        for (var i = 0; i < str.length; i++) {
            var c = str.charCodeAt(i)
            if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
                var next = str.charCodeAt(i + 1)
                if (next >= 0xDC00 && next <= 0xDFFF) {
                    c = 0x10000 + ((c - 0xD800) << 10) + (next - 0xDC00)
                    i++
                }
            }
            if (c < 0x80) {
                bytes.push(c)
            } else if (c < 0x800) {
                bytes.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F))
            } else if (c < 0x10000) {
                bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F))
            } else {
                bytes.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 0x3F), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F))
            }
        }
        return bytes
    }

    function _icalFoldLine(line) {
        var utf8Bytes = _toUtf8Bytes(line)
        if (utf8Bytes.length <= 75) return [line]
        var segments = []
        var byteIdx = 0
        var charIdx = 0
        var isFirst = true
        while (byteIdx < utf8Bytes.length) {
            // Continuation lines carry a leading SPACE (RFC 5545 §3.1), so limit content to 74 bytes.
            var maxBytes = isFirst ? 75 : 74
            var segEnd = Math.min(byteIdx + maxBytes, utf8Bytes.length)
            while (segEnd > byteIdx && (utf8Bytes[segEnd] & 0xC0) === 0x80) segEnd--
            var segBytes = segEnd - byteIdx
            var bUsed = 0
            var startChar = charIdx
            while (bUsed < segBytes && charIdx < line.length) {
                var ch = line.charCodeAt(charIdx)
                if (ch >= 0xD800 && ch <= 0xDBFF && charIdx + 1 < line.length) {
                    var ch2 = line.charCodeAt(charIdx + 1)
                    if (ch2 >= 0xDC00 && ch2 <= 0xDFFF) { bUsed += 4; charIdx += 2; continue }
                }
                bUsed += (ch < 0x80) ? 1 : (ch < 0x800) ? 2 : (ch < 0x10000) ? 3 : 4
                charIdx++
            }
            var seg = line.substring(startChar, charIdx)
            segments.push(isFirst ? seg : " " + seg)
            byteIdx = segEnd
            isFirst = false
        }
        return segments
    }

    function _icalEscapeText(text) {
        if (!text) return ""
        return text.replace(/\\/g, "\\\\")
                   .replace(/;/g, "\\;")
                   .replace(/,/g, "\\,")
                   .replace(/\r\n/g, "\\n")
                   .replace(/\r/g, "\\n")
                   .replace(/\n/g, "\\n")
    }

    function _toIcalTimestamp(isoStr) {
        if (!isoStr) return ""
        var d = new Date(isoStr)
        if (isNaN(d.getTime())) return ""
        var p = function(n) { return n < 10 ? "0" + n : "" + n }
        return d.getUTCFullYear() + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) +
               "T" + p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds()) + "Z"
    }

    function _toIcalDate(dateStr) {
        if (!dateStr) return ""
        return dateStr.replace(/-/g, "")
    }

    function _addVtodoLines(allLines, task, parentUuid, dtstamp) {
        allLines.push("BEGIN:VTODO")
        allLines.push("UID:" + task.uuid)
        allLines.push("DTSTAMP:" + dtstamp)
        allLines.push("SUMMARY:" + _icalEscapeText(task.title))
        if (task.dueDate) {
            allLines.push("DUE;VALUE=DATE:" + _toIcalDate(task.dueDate))
        }
        allLines.push("STATUS:" + (task.done ? "COMPLETED" : "NEEDS-ACTION"))
        if (task.done && task.modifiedAt) {
            allLines.push("COMPLETED:" + _toIcalTimestamp(task.modifiedAt))
        }
        if (task.priority !== undefined && task.priority !== null) {
            var icalPriority = 0
            if (task.priority === 2) icalPriority = 1
            else if (task.priority === 1) icalPriority = 5
            if (icalPriority > 0) {
                allLines.push("PRIORITY:" + icalPriority)
            }
        }
        if (task.category) {
            allLines.push("CATEGORIES:" + _icalEscapeText(task.category))
        }
        if (task.createdAt) {
            allLines.push("CREATED:" + _toIcalTimestamp(task.createdAt))
        }
        if (task.modifiedAt) {
            allLines.push("LAST-MODIFIED:" + _toIcalTimestamp(task.modifiedAt))
        }
        if (parentUuid) {
            allLines.push("RELATED-TO;RELTYPE=PARENT:" + parentUuid)
        }
        allLines.push("END:VTODO")
    }

    // Returns the iCalendar text, or null when no task has a due date.
    function _buildIcs() {
        var dtstamp = _toIcalTimestamp(new Date().toISOString())

        var allLines = []
        allLines.push("BEGIN:VCALENDAR")
        allLines.push("VERSION:2.0")
        allLines.push("PRODID:-//KDoit//KDoit//EN")

        var vtodoCount = 0
        for (var i = 0; i < count; i++) {
            var t = get(i)
            if (!t.dueDate || t.dueDate === "") continue
            _addVtodoLines(allLines, t, null, dtstamp)
            vtodoCount++
            var sub = t.sublist
            var subCount = (sub && typeof sub.count === "number") ? sub.count : (sub ? sub.length || 0 : 0)
            for (var j = 0; j < subCount; j++) {
                var s = (sub && typeof sub.get === "function") ? sub.get(j) : sub[j]
                _addVtodoLines(allLines, s, t.uuid, dtstamp)
            }
        }

        if (vtodoCount === 0) return null

        allLines.push("END:VCALENDAR")

        var foldedLines = []
        for (var f = 0; f < allLines.length; f++) {
            var segs = _icalFoldLine(allLines[f])
            for (var k = 0; k < segs.length; k++)
                foldedLines.push(segs[k])
        }
        // RFC 5545: every content line, including the last, ends with CRLF.
        return foldedLines.join("\r\n") + "\r\n"
    }

    // Records the change in the widget-settings copy right away, then queues a
    // file write. intent: "user" (default), "merge", "destructive", "defaults".
    function save(intent) {
        _updateConfigCopy()
        _writeDirty = true
        _intent = _maxIntent(_intent, intent || "user")
        _pump()
    }

    function _parseMarkdown(md) {
        var tasks = []
        if (!md || md.trim() === "") return tasks
        var lines = md.split("\n")
        var currentTask = null
        var commentRe = /<!--\s*kdoit-id:([a-fA-F0-9-]+)(?:\s+modifiedAt:([^\s]+))?\s*-->/

        var parseMeta = function(text) {
            var uuid = null, modifiedAt = null
            var m = commentRe.exec(text)
            if (m) {
                uuid = m[1]
                modifiedAt = m[2] || null
                text = text.replace(commentRe, "").trim()
            }
            var category = ""
            var catMatch = /(?:^|\s)#([^\s#]+(?:\s+[^\s#]+)*)$/.exec(text)
            if (catMatch) {
                category = catMatch[1]
                text = text.substring(0, catMatch.index).trim()
            }
            var dueDate = ""
            var calIdx = text.indexOf("📅")
            if (calIdx !== -1) {
                var dateMatch = /\d{4}-\d{2}-\d{2}/.exec(text.substring(calIdx))
                if (dateMatch) {
                    dueDate = dateMatch[0]
                    text = text.substring(0, calIdx).trim()
                }
            }
            var priority = 1
            var highIdx = text.lastIndexOf("⏫")
            var medIdx  = text.lastIndexOf("🔼")
            var lowIdx  = text.lastIndexOf("🔽")
            var maxIdx = Math.max(highIdx, medIdx, lowIdx)
            if (maxIdx !== -1) {
                if (maxIdx === highIdx) priority = 2
                else if (maxIdx === medIdx) priority = 1
                else priority = 0
                text = text.substring(0, maxIdx).trim()
            }
            return { title: text, priority: priority, dueDate: dueDate, category: category, uuid: uuid, modifiedAt: modifiedAt }
        }

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i]
            var subMatch = /^[ \t]{2,}- \[([ xX])\]\s+(.*)$/.exec(line)
            if (subMatch && currentTask) {
                var subText = subMatch[2]
                var subDone = subMatch[1].toLowerCase() === "x"
                var subCommentMatch = commentRe.exec(subText)
                var subUuid = null
                if (subCommentMatch) {
                    subUuid = subCommentMatch[1]
                    subText = subText.replace(commentRe, "").trim()
                }
                currentTask.sublist.push({ uuid: subUuid || newUuid(), title: subText.trim(), done: subDone })
                continue
            }
            var topMatch = /^- \[([ xX])\]\s+(.*)$/.exec(line)
            if (topMatch) {
                if (currentTask) tasks.push(currentTask)
                var done = topMatch[1].toLowerCase() === "x"
                var meta = parseMeta(topMatch[2])
                currentTask = {
                    uuid: meta.uuid,
                    title: meta.title,
                    done: done,
                    priority: meta.priority,
                    category: meta.category,
                    dueDate: meta.dueDate,
                    modifiedAt: meta.modifiedAt,
                    sublist: []
                }
            }
        }
        if (currentTask) tasks.push(currentTask)
        return tasks
    }

    function mergeImportedTasks(parsedTasks) {
        var imported = 0
        var updated = 0
        var now = new Date().toISOString()
        var addToTop = cfg.addToTop
        var byUuid = {}
        for (var i = 0; i < count; i++) {
            var cur = get(i)
            if (cur.uuid) byUuid[cur.uuid] = i
        }
        var seenUuids = {}
        var deduped = []
        for (var d = parsedTasks.length - 1; d >= 0; d--) {
            var pt = parsedTasks[d]
            if (pt.uuid && seenUuids[pt.uuid]) continue
            if (pt.uuid) seenUuids[pt.uuid] = true
            deduped.unshift(pt)
        }
        for (var j = 0; j < deduped.length; j++) {
            var parsed = deduped[j]
            if (parsed.uuid && byUuid[parsed.uuid] !== undefined) {
                var idx = byUuid[parsed.uuid]
                var existing = get(idx)
                if (parsed.modifiedAt && parsed.modifiedAt > existing.modifiedAt) {
                    setProperty(idx, "title", parsed.title)
                    setProperty(idx, "done", parsed.done)
                    setProperty(idx, "priority", parsed.priority)
                    setProperty(idx, "category", parsed.category)
                    setProperty(idx, "dueDate", parsed.dueDate)
                    setProperty(idx, "modifiedAt", parsed.modifiedAt)
                    var sub = existing.sublist
                    if (sub && typeof sub.clear === "function") {
                        sub.clear()
                        for (var k = 0; k < parsed.sublist.length; k++)
                            sub.append(parsed.sublist[k])
                    } else {
                        setProperty(idx, "sublist", parsed.sublist)
                    }
                    updated++
                }
            } else {
                // No UUID match -skip if a task with the same title already exists
                // (prevents duplication when importing a file without UUID comments)
                var existsByTitle = false
                for (var ti = 0; ti < count; ti++) {
                    if (get(ti).title === parsed.title) { existsByTitle = true; break }
                }
                if (!existsByTitle) {
                    var newTask = normalizeTask({
                        uuid: parsed.uuid || newUuid(),
                        title: parsed.title,
                        done: parsed.done,
                        priority: parsed.priority,
                        category: parsed.category,
                        dueDate: parsed.dueDate,
                        sublist: parsed.sublist,
                        createdAt: now,
                        modifiedAt: parsed.modifiedAt || now
                    })
                    if (addToTop) {
                        insert(0, newTask)
                        for (var uuid in byUuid) byUuid[uuid] = byUuid[uuid] + 1
                    } else {
                        append(newTask)
                    }
                    imported++
                }
            }
        }
        return { imported: imported, updated: updated }
    }

    function importFromMarkdown(mdText) {
        try {
            if (!mdText || mdText.trim() === "") return { imported: 0, updated: 0 }
            var parsed = _parseMarkdown(mdText)
            var result = mergeImportedTasks(parsed)
            if (result.imported > 0 || result.updated > 0)
                save()
            return result
        } catch(e) {
            console.error("KDoit markdown import failed:", e)
            return { imported: 0, updated: 0, error: e.toString() }
        }
    }

    function addTask(title, priority, toTop) {
        if (title.trim() === "") return
        var task = {
            uuid: newUuid(),
            title: title,
            done: false,
            priority: priority,
            category: "",
            createdAt: new Date().toISOString(),
            modifiedAt: new Date().toISOString(),
            dueDate: "",
            sublist: []
        }
        if (toTop)
            insert(0, task)
        else
            append(task)
        save()
    }

    function removeTask(index) {
        if (index < 0 || index >= count) return
        _addTomb(get(index).uuid)
        remove(index)
        save()
    }

    function removeTasks(indices) {
        var sorted = indices.slice().sort(function(a, b) { return b - a })
        for (var i = 0; i < sorted.length; i++) {
            if (sorted[i] >= 0 && sorted[i] < count) {
                _addTomb(get(sorted[i]).uuid)
                remove(sorted[i], 1)
            }
        }
        save()
    }

    function moveTask(from, to) {
        if (from === to) return
        if (from < 0 || from >= count || to < 0 || to >= count) return
        move(from, to, 1)
        save()
    }

    function setTaskProperty(index, key, value) {
        if (index < 0 || index >= count) return
        if (key === "sublist") {
            // setProperty with an array doesn't reliably set up a child ListModel
            // with the correct roles; manipulate the existing child model directly.
            var sub = get(index).sublist
            if (sub && typeof sub.clear === "function") {
                sub.clear()
                for (var i = 0; i < value.length; i++)
                    sub.append(value[i])
            } else {
                setProperty(index, key, value)
            }
        } else {
            setProperty(index, key, value)
        }
        touch(index)
        save()
    }

    // Re-inserts a deleted task (undo) without saving. The tombstone is dropped
    // and modifiedAt bumped so a tombstone already synced elsewhere loses.
    function restoreTask(index, task) {
        var t = normalizeTask(task)
        _removeTomb(t.uuid)
        var clamped = Math.max(0, Math.min(index, count))
        insert(clamped, {
            uuid: t.uuid,
            title: t.title,
            done: t.done,
            priority: t.priority,
            category: t.category,
            createdAt: t.createdAt,
            modifiedAt: new Date().toISOString(),
            dueDate: t.dueDate,
            sublist: normalizeSublist(t.sublist)
        })
    }

    function insertTask(index, task) {
        restoreTask(index, task)
        save()
    }

    function deleteCompleted() {
        var changed = false
        for (var i = count - 1; i >= 0; i--) {
            if (get(i).done === true) {
                _addTomb(get(i).uuid)
                remove(i)
                changed = true
            }
        }
        if (changed)
            save()
    }

    function clearCategoryFromAll(oldCategory) {
        var changed = false
        var now = new Date().toISOString()
        var lower = oldCategory.toLowerCase()
        for (var i = 0; i < count; i++) {
            if (get(i).category.toLowerCase() === lower) {
                setProperty(i, "category", "")
                setProperty(i, "modifiedAt", now)
                changed = true
            }
        }
        if (changed)
            save()
    }

    function migrateCategoryCase(managedCats) {
        var changed = false
        var now = new Date().toISOString()
        for (var i = 0; i < count; i++) {
            var cat = get(i).category
            if (cat === "") continue
            var matched = false
            for (var j = 0; j < managedCats.length; j++) {
                if (managedCats[j].toLowerCase() === cat.toLowerCase()) {
                    if (managedCats[j] !== cat) {
                        setProperty(i, "category", managedCats[j])
                        changed = true
                    }
                    matched = true
                    break
                }
            }
            if (!matched) {
                managedCats.push(cat)
            }
        }
        if (changed)
            save()
        return managedCats
    }

    Component.onCompleted: {
        if (!cfg) {
            console.warn("KDoit TaskModel: no cfg object; storage disabled")
            return
        }
        _tmpToken = _randomHex(8)
        var p = _normalizePath(cfg.storagePath)
        if (p === "") p = _defaultPath()
        _path = p
        if (cfg.storagePath !== p)
            cfg.storagePath = p
        load()
        _started = true
    }
}
