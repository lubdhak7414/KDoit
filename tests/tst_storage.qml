// Storage safety tests for TaskModel.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests
import QtQuick
import QtTest
import org.kde.plasma.plasma5support as P5
import "../contents/ui"

TestCase {
    id: tc
    name: "Storage"

    property string tmp: ""
    property int _seq: 0

    // ---- shell helper ---------------------------------------------------

    P5.DataSource {
        id: sh
        engine: "executable"
        connectedSources: []
        property var results: ({})
        onNewData: function(source, data) {
            disconnectSource(source)
            var r = Object.assign({}, results)
            r[source] = { code: data["exit code"], out: data.stdout || "", err: data.stderr || "" }
            results = r
        }
    }

    function run(cmd) {
        _seq++
        var c = ": t" + _seq + "; " + cmd
        sh.connectSource(c)
        tryVerify(function() { return sh.results[c] !== undefined }, 15000, "shell: " + cmd)
        return sh.results[c]
    }

    function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function writeFile(path, text) {
        var r = run("printf '%s' " + q(text) + " > " + q(path))
        compare(r.code, 0, "writeFile " + path + ": " + r.err)
    }

    function readFile(path) { return run("cat -- " + q(path)).out }
    function md5(path) { return run("md5sum < " + q(path)).out.trim() }
    function sh0(cmd) { return run(cmd).code === 0 }

    function mkdir(name) {
        var d = tmp + "/" + name
        compare(run("mkdir -p -- " + q(d)).code, 0)
        return d
    }

    function task(uuid, title, modifiedAt, sub) {
        return {
            uuid: uuid, title: title, done: false, priority: 1, category: "",
            createdAt: "2020-01-01T00:00:00.000Z", modifiedAt: modifiedAt,
            dueDate: "", sublist: sub || []
        }
    }

    function doc(tasks, deleted) {
        return JSON.stringify({ version: 1, tasks: tasks, deleted: deleted || [] }, null, 2)
    }

    function titles(m) {
        var out = []
        for (var i = 0; i < m.count; i++) out.push(m.get(i).title)
        return out.sort()
    }

    function fileTitles(path) {
        var d = JSON.parse(readFile(path))
        return d.tasks.map(function(t) { return t.title }).sort()
    }

    // ---- harness --------------------------------------------------------

    Component {
        id: cfgComp
        QtObject {
            property string tasksJson: "[]"
            property string tombstonesJson: "[]"
            property string storagePath: ""
            property bool migratedToFile: false
            property bool syncEnabled: false
            property bool markdownExport: false
            property string markdownPath: ""
            property bool enableIcsExport: false
            property bool addToTop: false
        }
    }

    Component {
        id: harnessComp
        Item {
            id: h
            property var cfg
            property alias model: tm
            property string writerSource: ""
            property int shellCmds: 0
            property var migratedFlips: []

            P5.DataSource {
                id: writer
                engine: "executable"
                connectedSources: []
                onNewData: function(source, data) {
                    disconnectSource(source)
                    if (source === h.writerSource) { wd.stop(); h.writerSource = "" }
                    tm.shellResult(source, data["exit code"], data.stdout || "", data.stderr || "")
                }
                function run(cmd) { h.shellCmds++; h.writerSource = cmd; wd.restart(); connectSource(cmd) }
            }
            Timer {
                id: wd
                interval: 15000
                onTriggered: { writer.disconnectSource(h.writerSource); h.writerSource = ""; tm.shellTimeout() }
            }
            P5.DataSource {
                id: reader
                engine: "executable"
                connectedSources: []
                onNewData: function(source, data) {
                    disconnectSource(source)
                    tm.loadFromShell(data["exit code"], data.stdout || "", source)
                }
                function run(path) { connectSource(tm._readCmd(path)) }
            }
            Connections {
                target: h.cfg
                function onStoragePathChanged() { tm.storagePathChanged() }
                function onMigratedToFileChanged() {
                    // Record the write state at the moment the flag flips.
                    h.migratedFlips = h.migratedFlips.concat([{ value: h.cfg.migratedToFile, fileSig: tm._fileSig }])
                }
            }
            TaskModel {
                id: tm
                cfg: h.cfg
                onRunShellCmd: function(cmd) { writer.run(cmd) }
                onRequestFileLoad: function(path) { reader.run(path) }
            }
        }
    }

    function harness(cfgProps) {
        var c = createTemporaryObject(cfgComp, tc, cfgProps)
        verify(c)
        var h = createTemporaryObject(harnessComp, tc, { cfg: c })
        verify(h)
        return h
    }

    function settle(h) {
        var m = h.model
        tryVerify(function() {
            return m._loaded && !m._writeBusy && !m._readInFlight && !m._readWanted &&
                   !m._exportsPending && (!m._writeDirty || m._writeBlocked)
        }, 20000, "model did not settle")
        wait(50)
        verify(!m._writeBusy && !m._readInFlight, "model became busy again")
    }

    function noTmpLeftovers(dir) {
        var r = run("ls -A -- " + q(dir) + " | grep '\\.tmp\\.' || true")
        compare(r.out, "", "leftover temp files in " + dir)
    }

    // ---- lifecycle ------------------------------------------------------

    function initTestCase() {
        var r = run("mktemp -d")
        compare(r.code, 0)
        tmp = r.out.trim()
        verify(tmp.length > 0)
    }

    function cleanupTestCase() {
        if (tmp !== "") run("chmod -R u+rwx -- " + q(tmp) + "; rm -rf -- " + q(tmp))
    }

    // ---- cases ----------------------------------------------------------

    function test_01_missing_file_fresh_config_gets_samples() {
        var d = mkdir("t01")
        var p = d + "/tasks.json"
        var h = harness({ storagePath: p })
        compare(h.cfg.migratedToFile, false)
        settle(h)
        compare(h.model.count, 5)
        compare(h.model.storageError, "")
        compare(h.cfg.migratedToFile, true)
        // It flipped exactly once, after the write reported OK (signature known).
        compare(h.migratedFlips.length, 1)
        verify(h.migratedFlips[0].fileSig !== "" && h.migratedFlips[0].fileSig !== "MISSING",
               "migratedToFile flipped before a successful write")
        compare(JSON.parse(readFile(p)).tasks.length, 5)
        noTmpLeftovers(d)
    }

    function test_01b_failed_write_keeps_migrated_false() {
        var d = mkdir("t01b")
        var p = d + "/tasks.json"
        run("chmod 555 -- " + q(d))
        var h = harness({ storagePath: p })
        settle(h)
        compare(h.cfg.migratedToFile, false)
        compare(h.model.storageError, "write")
        verify(!sh0("test -e " + q(p)))
        run("chmod 755 -- " + q(d))
    }

    function test_02_unreadable_file_fresh_config() {
        var d = mkdir("t02")
        var p = d + "/tasks.json"
        writeFile(p, doc([task("u-a", "A", "2025-01-01T00:00:00.000Z")]))
        var before = md5(p)
        run("chmod 000 -- " + q(p))
        var h = harness({ storagePath: p })
        settle(h)
        compare(h.model.count, 0)
        compare(h.model.storageError, "unreadable")
        compare(h.cfg.migratedToFile, false)
        compare(h.shellCmds, 0, "no write commands may run")
        // A later save must not write blind either.
        h.model.addTask("new", 1, false)
        settle(h)
        compare(h.model.storageError, "unreadable")
        run("chmod 644 -- " + q(p))
        compare(md5(p), before)
        noTmpLeftovers(d)
    }

    function test_02b_path_is_directory() {
        var d = mkdir("t02b")
        var p = d + "/tasks.json"
        run("mkdir -- " + q(p))
        var h = harness({ storagePath: p })
        settle(h)
        compare(h.model.count, 0)
        compare(h.model.storageError, "unreadable")
        compare(h.shellCmds, 0)
        verify(sh0("test -d " + q(p)))
        compare(h.cfg.migratedToFile, false)
    }

    function test_02c_missing_parent_dir_non_default_path() {
        var d = mkdir("t02c")
        var p = d + "/nope/tasks.json"
        var h = harness({ storagePath: p })
        settle(h)
        compare(h.model.count, 0)
        compare(h.model.storageError, "nodir")
        compare(h.shellCmds, 0)
        verify(!sh0("test -e " + q(d + "/nope")))
    }

    function test_03_empty_file_recovers_from_bak() {
        var d = mkdir("t03")
        var p = d + "/tasks.json"
        writeFile(p, "")
        writeFile(p + ".bak", doc([task("u-a", "A", "2025-01-01T00:00:00.000Z"),
                                   task("u-b", "B", "2025-01-02T00:00:00.000Z")]))
        var h = harness({ storagePath: p })
        settle(h)
        compare(titles(h.model), ["A", "B"])
        compare(fileTitles(p), ["A", "B"])
        compare(h.model.storageError, "")
        compare(h.cfg.migratedToFile, true)
    }

    function test_04_defaults_refused_on_nonempty_file() {
        var d = mkdir("t04")
        var p = d + "/tasks.json"
        writeFile(p, doc([task("u-a", "A", "2025-01-01T00:00:00.000Z"),
                          task("u-b", "B", "2025-01-02T00:00:00.000Z")]))
        var h = harness({ storagePath: p, migratedToFile: true })
        settle(h)
        compare(titles(h.model), ["A", "B"])
        var before = md5(p)
        // Force the sample write path against the (matching) signature.
        h.model._injectSamples()
        h.model.save("defaults")
        settle(h)
        compare(md5(p), before, "file changed despite defaults intent")
        compare(titles(h.model), ["A", "B"])
        verify(h.model._samplesRefused)
        noTmpLeftovers(d)
    }

    function test_05_large_round_trip() {
        var d = mkdir("t05")
        var p = d + "/tasks.json"
        var h = harness({ storagePath: p, migratedToFile: true })
        settle(h)
        compare(h.model.count, 0)
        var m = h.model
        for (var i = 0; i < 300; i++) {
            var sub = []
            for (var j = 0; j < 5; j++)
                sub.push({ uuid: "s-" + i + "-" + j, title: "Sub " + j + " üñï 🚀 'q' \"dq\" \\ $HOME `x`", done: j % 2 === 0 })
            m.append(m.normalizeTask({
                uuid: "t-" + i, title: "Task " + i + " ✓ éè 📅 'single' \"double\" %s \\n",
                done: i % 3 === 0, priority: i % 3, category: i % 2 ? "Work" : "",
                createdAt: "2025-01-01T00:00:00.000Z", modifiedAt: "2025-02-01T00:00:00.000Z",
                dueDate: i % 5 ? "" : "2025-03-01", sublist: sub
            }))
        }
        m.save()
        settle(h)
        compare(m.storageError, "")
        var size = parseInt(run("wc -c < " + q(p)).out.trim())
        verify(size > 131072, "payload should exceed the old argv limit, got " + size)
        var fileDoc = JSON.parse(readFile(p))
        compare(JSON.stringify(fileDoc.tasks), JSON.stringify(m._tasksArray()))

        // A second instance loading the file sees exactly the same data.
        var h2 = harness({ storagePath: p, migratedToFile: true })
        settle(h2)
        compare(JSON.stringify(h2.model._tasksArray()), JSON.stringify(m._tasksArray()))
        noTmpLeftovers(d)
    }

    function test_06_external_change_conflict_union() {
        var d = mkdir("t06")
        var p = d + "/tasks.json"
        writeFile(p, doc([task("u-a", "A", "2025-01-01T00:00:00.000Z")]))
        var h = harness({ storagePath: p, migratedToFile: true })
        settle(h)
        compare(titles(h.model), ["A"])
        var external = doc([task("u-a", "A", "2025-01-01T00:00:00.000Z"),
                            task("u-b", "B", "2025-01-03T00:00:00.000Z")])
        writeFile(p, external)
        var conflictsBefore = h.model._conflictCount
        h.model.addTask("C", 1, false)
        settle(h)
        verify(h.model._conflictCount > conflictsBefore, "expected a CONFLICT")
        compare(titles(h.model), ["A", "B", "C"])
        compare(fileTitles(p), ["A", "B", "C"])
        compare(readFile(p + ".bak"), external)
        noTmpLeftovers(d)
    }

    function test_07_ten_saves() {
        var d = mkdir("t07")
        var p = d + "/tasks.json"
        var h = harness({ storagePath: p, migratedToFile: true })
        settle(h)
        for (var i = 0; i < 10; i++)
            h.model.addTask("T" + i, 1, false)
        settle(h)
        compare(JSON.stringify(JSON.parse(readFile(p)).tasks), JSON.stringify(h.model._tasksArray()))
        compare(h.model.count, 10)
        noTmpLeftovers(d)
    }

    function test_08_stale_file_sync_off_deletes_nothing() {
        var d = mkdir("t08")
        var p = d + "/tasks.json"
        // The file is newer than every local task and even carries a tombstone
        // for C; with sync off and on the initial load nothing may be deleted.
        writeFile(p, doc([task("u-a", "A-remote", "2025-06-01T00:00:00.000Z")],
                         [{ uuid: "u-c", deletedAt: new Date().toISOString() }]))
        var local = [task("u-a", "A", "2020-01-01T00:00:00.000Z"),
                     task("u-b", "B", "2020-01-01T00:00:00.000Z"),
                     task("u-c", "C", "2020-01-01T00:00:00.000Z")]
        var h = harness({ storagePath: p, migratedToFile: true, syncEnabled: false,
                          tasksJson: JSON.stringify(local) })
        settle(h)
        compare(titles(h.model), ["A-remote", "B", "C"])
        compare(fileTitles(p), ["A-remote", "B", "C"])
    }

    function test_08b_tombstone_deletes_on_live_sync_read() {
        var d = mkdir("t08b")
        var p = d + "/tasks.json"
        var a = task("u-a", "A", "2025-01-01T00:00:00.000Z")
        var b = task("u-b", "B", "2025-01-01T00:00:00.000Z")
        var c = task("u-c", "C", "2025-01-01T00:00:00.000Z")
        writeFile(p, doc([a, b, c]))
        var h = harness({ storagePath: p, migratedToFile: true, syncEnabled: true })
        settle(h)
        compare(titles(h.model), ["A", "B", "C"])
        // Another machine deleted B (tombstone) and simply lacks C (no tombstone).
        writeFile(p, doc([a], [{ uuid: "u-b", deletedAt: new Date().toISOString() }]))
        h.model.requestRead()
        settle(h)
        compare(titles(h.model), ["A", "C"])
        compare(fileTitles(p), ["A", "C"])
        var fd = JSON.parse(readFile(p))
        compare(fd.deleted.length, 1)
        compare(fd.deleted[0].uuid, "u-b")
        verify(sh0("ls -- " + q(p) + ".bak-* >/dev/null 2>&1"), "expected a timestamped snapshot")
    }

    function test_09_empty_file_keeps_model_on_initial_load() {
        var d = mkdir("t09")
        var p = d + "/tasks.json"
        writeFile(p, doc([]))
        var local = [task("u-a", "A", "2025-01-01T00:00:00.000Z"),
                     task("u-b", "B", "2025-01-01T00:00:00.000Z")]
        var h = harness({ storagePath: p, migratedToFile: true, syncEnabled: true,
                          tasksJson: JSON.stringify(local) })
        settle(h)
        compare(titles(h.model), ["A", "B"])
        compare(fileTitles(p), ["A", "B"])
    }

    function test_10_path_switch_to_existing_file_unions() {
        var d = mkdir("t10")
        var p1 = d + "/one.json"
        var p2 = d + "/two.json"
        writeFile(p1, doc([task("u-a", "A", "2025-01-01T00:00:00.000Z")]))
        writeFile(p2, doc([task("u-b", "B", "2025-01-01T00:00:00.000Z")]))
        var h = harness({ storagePath: p1, migratedToFile: true, syncEnabled: true })
        settle(h)
        compare(titles(h.model), ["A"])
        h.cfg.storagePath = p2
        settle(h)
        compare(h.model._path, p2)
        compare(titles(h.model), ["A", "B"])
        compare(fileTitles(p2), ["A", "B"])
        compare(fileTitles(p1), ["A"])
    }

    function test_11_symlink_survives() {
        var d = mkdir("t11")
        var real = d + "/real/tasks.json"
        var link = d + "/link.json"
        run("mkdir -p -- " + q(d + "/real"))
        writeFile(real, doc([task("u-a", "A", "2025-01-01T00:00:00.000Z")]))
        compare(run("ln -s -- " + q(real) + " " + q(link)).code, 0)
        var h = harness({ storagePath: link, migratedToFile: true })
        settle(h)
        h.model.addTask("B", 1, false)
        settle(h)
        verify(sh0("test -L " + q(link)), "symlink was replaced")
        compare(fileTitles(real), ["A", "B"])
        noTmpLeftovers(d)
        noTmpLeftovers(d + "/real")
    }

    function test_12_corrupt_file_not_overwritten_when_model_empty() {
        var d = mkdir("t12")
        var p = d + "/tasks.json"
        writeFile(p, "{ this is not json")
        var before = md5(p)
        var h = harness({ storagePath: p })
        settle(h)
        compare(h.model.count, 0)
        compare(h.model.storageError, "corrupt")
        compare(h.shellCmds, 0)
        compare(md5(p), before)
    }

    function test_13_exports_written() {
        var d = mkdir("t13")
        var p = d + "/tasks.json"
        var t = task("u-a", "A", "2025-01-01T00:00:00.000Z")
        t.dueDate = "2025-03-01"
        writeFile(p, doc([t]))
        var h = harness({ storagePath: p, migratedToFile: true, markdownExport: true, enableIcsExport: true })
        settle(h)
        h.model.addTask("B", 1, false)
        settle(h)
        verify(readFile(d + "/tasks.md").indexOf("kdoit-id:u-a") !== -1)
        verify(readFile(d + "/tasks.ics").indexOf("UID:u-a") !== -1)
        noTmpLeftovers(d)
    }

    function test_15_native_base64_matches_js_encoder() {
        // Qt.btoa(string) is deprecated in Qt 6.12 and warns on every use.
        failOnWarning(/Qt\.btoa/)
        var h = harness({ storagePath: tmp + "/t15-unused.json", migratedToFile: true })
        var m = h.model
        verify(m._base64Mode !== "js", "no native base64 on this Qt; writes use the slow JS encoder")
        var s = "plain ✓ éè 日本語 🚀 'q' \"dq\" \\ $HOME `x` \u0000 \r\n end \ud83d"
        for (var n = 0; n < 5; n++) {
            var t = s.substring(n, s.length - n)
            var js = m._base64Bytes(m._toUtf8Bytes(t))
            if (m._base64Mode === "buffer" || t.indexOf("\ud83d end") === -1)
                compare(m._base64(t), js, JSON.stringify(t))
            compare(m._base64Length(js), m._toUtf8Bytes(t).length)
        }
        compare(m._base64(""), "")
        settle(h)
    }

    function test_14_malformed_fields_keep_every_task() {
        var d = mkdir("t14")
        var p = d + "/tasks.json"
        // Hand-edited or foreign data: wrong field types and junk sublist
        // entries. Every task must survive a load and the next save.
        var a = task("u-a", "A", "2025-01-01T00:00:00.000Z")
        a.title = 42
        a.priority = "2"
        var b = task(7, "B", "2025-01-01T00:00:00.000Z",
                     [null, { uuid: "s-1", title: 5, done: true }, "junk"])
        b.dueDate = null
        var c = task("u-c", "C", "2025-01-01T00:00:00.000Z")
        writeFile(p, doc([a, b, c]))
        var h = harness({ storagePath: p, migratedToFile: true })
        settle(h)
        compare(titles(h.model), ["42", "B", "C"])
        h.model.addTask("D", 1, false)
        settle(h)
        compare(h.model.storageError, "")
        compare(fileTitles(p), ["42", "B", "C", "D"])
        var byUuid = {}
        JSON.parse(readFile(p)).tasks.forEach(function(t) { byUuid[t.uuid] = t })
        compare(byUuid["u-a"].priority, 2)
        compare(byUuid["7"].dueDate, "")
        compare(byUuid["7"].sublist.length, 1)
        compare(byUuid["7"].sublist[0].title, "5")
        compare(byUuid["7"].sublist[0].done, true)
    }
}
