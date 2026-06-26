import QtQuick
import Qt.labs.platform as Platform
import org.kde.plasma.plasmoid

ListModel {
    id: model

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

    function _base64(str) {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        var bytes = []
        for (var i = 0; i < str.length; i++) {
            var c = str.charCodeAt(i)
            if (c < 0x80) {
                bytes.push(c)
            } else if (c < 0x800) {
                bytes.push(0xC0 | (c >> 6))
                bytes.push(0x80 | (c & 0x3F))
            } else if (c < 0x10000) {
                bytes.push(0xE0 | (c >> 12))
                bytes.push(0x80 | ((c >> 6) & 0x3F))
                bytes.push(0x80 | (c & 0x3F))
            } else {
                bytes.push(0xF0 | (c >> 18))
                bytes.push(0x80 | ((c >> 12) & 0x3F))
                bytes.push(0x80 | ((c >> 6) & 0x3F))
                bytes.push(0x80 | (c & 0x3F))
            }
        }
        var result = ""
        for (var j = 0; j < bytes.length; j += 3) {
            var b0 = bytes[j]
            var b1 = j + 1 < bytes.length ? bytes[j + 1] : 0
            var b2 = j + 2 < bytes.length ? bytes[j + 2] : 0
            result += chars[b0 >> 2]
            result += chars[((b0 & 3) << 4) | (b1 >> 4)]
            result += j + 1 < bytes.length ? chars[((b1 & 15) << 2) | (b2 >> 6)] : "="
            result += j + 2 < bytes.length ? chars[b2 & 63] : "="
        }
        return result
    }

    function touch(index) {
        if (index >= 0 && index < count)
            setProperty(index, "modifiedAt", new Date().toISOString())
    }

    function normalizeTask(t) {
        return {
            uuid: (t.uuid !== undefined && t.uuid !== "") ? t.uuid : newUuid(),
            title: t.title !== undefined ? t.title : "",
            done: t.done === true,
            priority: t.priority !== undefined ? t.priority : 1,
            category: (t.category !== undefined ? t.category : "").trim(),
            createdAt: t.createdAt !== undefined ? t.createdAt : new Date().toISOString(),
            modifiedAt: t.modifiedAt !== undefined ? t.modifiedAt : new Date().toISOString(),
            dueDate: t.dueDate !== undefined ? t.dueDate : "",
            sublist: normalizeSublist(t.sublist)
        }
    }

    function normalizeSublist(sub) {
        var out = []
        if (Array.isArray(sub)) {
            for (var i = 0; i < sub.length; i++) {
                out.push({
                    uuid: (sub[i].uuid !== undefined && sub[i].uuid !== "") ? sub[i].uuid : newUuid(),
                    title: sub[i].title !== undefined ? sub[i].title : "",
                    done: sub[i].done === true
                })
            }
        } else if (sub && typeof sub.count === "number" && typeof sub.get === "function") {
            for (var j = 0; j < sub.count; j++) {
                var e = sub.get(j)
                out.push({
                    uuid: (e.uuid !== undefined && e.uuid !== "") ? e.uuid : newUuid(),
                    title: e.title !== undefined ? e.title : "",
                    done: e.done === true
                })
            }
        } else if (sub && typeof sub.length === "number") {
            for (var k = 0; k < sub.length; k++) {
                var item = sub[k]
                if (item) out.push({
                    uuid: (item.uuid !== undefined && item.uuid !== "") ? item.uuid : newUuid(),
                    title: item.title !== undefined ? item.title : "",
                    done: item.done === true
                })
            }
        }
        return out
    }

    function _parseConfigJson(raw) {
        if (!raw || raw === "" || raw === "[]") return []
        try {
            var parsed = JSON.parse(raw)
            if (Array.isArray(parsed)) return parsed
            if (parsed && Array.isArray(parsed.tasks)) return parsed.tasks
            return []
        } catch(e) { return [] }
    }

    // Called by main.qml's fileReader DataSource after a shell-based cat of the file.
    // Overrides the model with file content (handles Syncthing external changes).
    function loadFromShell(json) {
        if (!json || json.trim() === "") return
        try {
            var doc = JSON.parse(json)
            var arr
            if (doc && Array.isArray(doc.tasks)) arr = doc.tasks
            else if (Array.isArray(doc)) arr = doc
            if (!arr) return
            clear()
            for (var i = 0; i < arr.length; i++)
                append(normalizeTask(arr[i]))
            // Keep tasksJson in sync so next restart doesn't need async read
            plasmoid.configuration.tasksJson = JSON.stringify(arr)
            modelReloaded()
        } catch(e) {}
    }

    function load() {
        clear()
        // XHR for local files is blocked in Plasma's QML environment; read from
        // KConfig (tasksJson) synchronously and kick off an async shell read of the
        // file so external changes (e.g. Syncthing) are applied on startup.
        var arr = _parseConfigJson(plasmoid.configuration.tasksJson)
        for (var i = 0; i < arr.length; i++)
            append(normalizeTask(arr[i]))
        var path = plasmoid.configuration.storagePath
        if (path !== "") requestFileLoad(path)
    }

    function save() {
        var path = plasmoid.configuration.storagePath
        if (path === "") return

        var doc = { version: 1, tasks: [] }
        for (var i = 0; i < count; i++) {
            var t = get(i)
            doc.tasks.push({
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
        var json = JSON.stringify(doc, null, 2)

        // Keep KConfig in sync so startup load() has reliable data even if file
        // read is unavailable or the file path changes.
        plasmoid.configuration.tasksJson = JSON.stringify(doc.tasks)

        // Write to file for Syncthing / external tool access.
        var b64 = _base64(json)
        var dir = path.substring(0, path.lastIndexOf("/"))
        var cmd = "mkdir -p '" + dir + "' && " +
            "printf '%s' '" + b64 + "' | base64 -d > '" + path + ".tmp' && " +
            "mv -f '" + path + ".tmp' '" + path + "'"
        runShellCmd(cmd)

        if (!plasmoid.configuration.migratedToFile)
            plasmoid.configuration.migratedToFile = true
    }

    function addTask(title, priority) {
        if (title.trim() === "") return
        append({
            uuid: newUuid(),
            title: title,
            done: false,
            priority: priority,
            category: "",
            createdAt: new Date().toISOString(),
            modifiedAt: new Date().toISOString(),
            dueDate: "",
            sublist: []
        })
        save()
    }

    function removeTask(index) {
        if (index < 0 || index >= count) return
        remove(index)
        save()
    }

    function removeTasks(indices) {
        var sorted = indices.slice().sort(function(a, b) { return b - a })
        for (var i = 0; i < sorted.length; i++) {
            if (sorted[i] >= 0 && sorted[i] < count)
                remove(sorted[i], 1)
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

    function insertTask(index, task) {
        var clamped = Math.max(0, Math.min(index, count))
        insert(clamped, {
            uuid: task.uuid || newUuid(),
            title: task.title,
            done: task.done,
            priority: task.priority,
            category: task.category,
            createdAt: task.createdAt,
            modifiedAt: task.modifiedAt || new Date().toISOString(),
            dueDate: task.dueDate,
            sublist: normalizeSublist(task.sublist)
        })
        save()
    }

    function deleteCompleted() {
        for (var i = count - 1; i >= 0; i--) {
            if (get(i).done === true)
                remove(i)
        }
        save()
    }

    Component.onCompleted: {
        var path = plasmoid.configuration.storagePath
        if (path === "") {
            var dataHome = Platform.StandardPaths.writableLocation(Platform.StandardPaths.GenericDataLocation)
            // writableLocation returns a file:// URL; strip the scheme to get a plain fs path
            if (dataHome.startsWith("file://"))
                dataHome = dataHome.substring(7)
            plasmoid.configuration.storagePath = dataHome + "/kdoit/tasks.json"
        } else if (path.startsWith("file://")) {
            // Fix paths already stored with the file:// prefix from a prior bad run
            plasmoid.configuration.storagePath = path.substring(7)
        }
        load()
    }
}
