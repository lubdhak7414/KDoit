import QtQuick
import QtCore
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
            // Combine surrogate pairs into a single code point before UTF-8 encoding.
            // charCodeAt returns individual UTF-16 units; without this, non-BMP chars
            // (emoji, U+10000+) each surrogate gets encoded as 3 bytes → invalid UTF-8.
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

    function _shellArg(s) {
        return "'" + s.replace(/'/g, "'\\''") + "'"
    }

    function touch(index) {
        if (index >= 0 && index < count)
            setProperty(index, "modifiedAt", new Date().toISOString())
    }

    function normalizeTask(t) {
        return {
            uuid: (t.uuid != null && t.uuid !== "") ? t.uuid : newUuid(),
            title: t.title != null ? t.title : "",
            done: t.done === true,
            priority: t.priority != null ? t.priority : 1,
            category: (t.category != null ? String(t.category) : "").trim(),
            createdAt: t.createdAt != null ? t.createdAt : new Date().toISOString(),
            modifiedAt: t.modifiedAt != null ? t.modifiedAt : new Date().toISOString(),
            dueDate: t.dueDate != null ? t.dueDate : "",
            sublist: normalizeSublist(t.sublist)
        }
    }

    function normalizeSublist(sub) {
        var out = []
        if (Array.isArray(sub)) {
            for (var i = 0; i < sub.length; i++) {
                out.push({
                    uuid: (sub[i].uuid != null && sub[i].uuid !== "") ? sub[i].uuid : newUuid(),
                    title: sub[i].title != null ? sub[i].title : "",
                    done: sub[i].done === true
                })
            }
        } else if (sub && typeof sub.count === "number" && typeof sub.get === "function") {
            for (var j = 0; j < sub.count; j++) {
                var e = sub.get(j)
                out.push({
                    uuid: (e.uuid != null && e.uuid !== "") ? e.uuid : newUuid(),
                    title: e.title != null ? e.title : "",
                    done: e.done === true
                })
            }
        }
        return out
    }

    function _parseConfigJson(raw) {
        if (!raw || raw === "" || raw === "[]") return []
        try {
            var parsed = JSON.parse(raw)
            if (Array.isArray(parsed)) return parsed.filter(function(x) { return x != null })
            return []
        } catch(e) { return [] }
    }

    // Called by main.qml's fileReader DataSource after a shell-based cat of the file.
    // Merges file content with in-memory model (uuid-based, newer modifiedAt wins).
    // Remote deletions are propagated via a knowledge-horizon heuristic: a local task
    // absent from the file is removed when its modifiedAt is no newer than the remote's
    // most recent task write (the remote "knew about" it and chose to omit it).
    // Tasks added locally after the remote's last write are kept.
    function loadFromShell(json) {
        if (!json || json.trim() === "") {
            if (count === 0 && !plasmoid.configuration.migratedToFile) {
                _addDefaultTasks()
                save()
                modelReloaded()
            }
            return
        }
        try {
            var doc = JSON.parse(json)
            var incoming
            if (doc && Array.isArray(doc.tasks)) incoming = doc.tasks
            else if (Array.isArray(doc)) incoming = doc
            if (!incoming) return

            var changed = false

            if (incoming.length === 0) {
                if (count > 0) {
                    // Remote wiped all tasks -propagate deletion
                    for (var w = count - 1; w >= 0; w--)
                        remove(w)
                    save()
                    modelReloaded()
                } else if (!plasmoid.configuration.migratedToFile) {
                    // Empty file on a fresh instance -inject defaults
                    _addDefaultTasks()
                    save()
                    modelReloaded()
                }
                return
            }

            // Compute the remote's knowledge horizon and UUID set from raw data,
            // before normalizeTask which would stamp a missing modifiedAt with now().
            var incomingMaxMtime = ""
            var incomingUuids = {}
            for (var p = 0; p < incoming.length; p++) {
                var raw = incoming[p]
                if (raw.uuid) incomingUuids[raw.uuid] = true
                if (raw.modifiedAt && raw.modifiedAt > incomingMaxMtime)
                    incomingMaxMtime = raw.modifiedAt
            }

            // Build uuid → index lookup for the current model
            var currentByUuid = {}
            for (var i = 0; i < count; i++) {
                var cur = get(i)
                currentByUuid[cur.uuid] = i
            }

            // Merge incoming tasks into the current model
            for (var j = 0; j < incoming.length; j++) {
                var inc = normalizeTask(incoming[j])
                // Treat a missing modifiedAt as epoch so external-tool tasks without
                // a timestamp never silently overwrite locally-modified data.
                if (!incoming[j].modifiedAt) inc.modifiedAt = "1970-01-01T00:00:00.000Z"
                var idx = currentByUuid[inc.uuid]
                if (idx !== undefined) {
                    // Task exists locally -update in-place if incoming is newer
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
                        // Sublist is a child ListModel -update in-place
                        var sub = existing.sublist
                        if (sub && typeof sub.clear === "function") {
                            sub.clear()
                            for (var k = 0; k < inc.sublist.length; k++)
                                sub.append(inc.sublist[k])
                        } else {
                            setProperty(idx, "sublist", inc.sublist)
                        }
                        changed = true
                    }
                } else {
                    // New task from remote -append and register in the map so a
                    // duplicate UUID in the incoming file is not appended twice.
                    append(inc)
                    currentByUuid[inc.uuid] = count - 1
                    changed = true
                }
            }

            // Propagate remote deletions: remove local tasks that the remote knew about
            // (local.modifiedAt <= incomingMaxMtime) but omitted from its file.
            if (incomingMaxMtime !== "") {
                for (var d = count - 1; d >= 0; d--) {
                    var localUuid = get(d).uuid
                    var localMtime = get(d).modifiedAt
                    if (!incomingUuids[localUuid] && localMtime <= incomingMaxMtime) {
                        remove(d)
                        changed = true
                    }
                }
            }

            // Only write back when the merge changed something -avoids an infinite
            // poll→read→save→mtime-change→poll loop. Note: save() bumps the file mtime
            // so one extra poll cycle fires per sync event; the second loadFromShell
            // finds changed=false and breaks the cycle.
            if (changed) {
                save()
                modelReloaded()
            }
        } catch(e) {
            console.warn("KDoit loadFromShell:", e)
        }
    }

    function _addDefaultTasks() {
        var now = new Date().toISOString()
        var today = now.substring(0, 10)
        var tomorrow = new Date(Date.now() + 86400000).toISOString().substring(0, 10)
        var nextWeek = new Date(Date.now() + 604800000).toISOString().substring(0, 10)
        append(normalizeTask({
            uuid: newUuid(),
            title: "Procrastinate effectively",
            done: false,
            priority: 2,
            category: "Work",
            createdAt: now,
            modifiedAt: now,
            dueDate: today,
            sublist: [
                { uuid: newUuid(), title: "Reorganize desk by color", done: false },
                { uuid: newUuid(), title: "Research best pen caps for clicking", done: false },
                { uuid: newUuid(), title: "Write a to-do list about writing to-do lists", done: true }
            ]
        }))
        append(normalizeTask({
            uuid: newUuid(),
            title: "Remember what I walked into this room for",
            done: false,
            priority: 1,
            category: "Personal",
            createdAt: now,
            modifiedAt: now,
            dueDate: tomorrow,
            sublist: []
        }))
        append(normalizeTask({
            uuid: newUuid(),
            title: "Water the fake plant",
            done: true,
            priority: 0,
            category: "Home",
            createdAt: now,
            modifiedAt: now,
            dueDate: "",
            sublist: []
        }))
        append(normalizeTask({
            uuid: newUuid(),
            title: "Contemplate the meaning of checkbox liberation",
            done: false,
            priority: 1,
            category: "Education",
            createdAt: now,
            modifiedAt: now,
            dueDate: nextWeek,
            sublist: [
                { uuid: newUuid(), title: "Read philosophy of task management", done: false },
                { uuid: newUuid(), title: "Question whether 'done' is truly ever achieved", done: false }
            ]
        }))
        append(normalizeTask({
            uuid: newUuid(),
            title: "Fix that one bug everyone pretends doesn't exist",
            done: false,
            priority: 2,
            category: "Work",
            createdAt: now,
            modifiedAt: now,
            dueDate: tomorrow,
            sublist: []
        }))
    }

    function load() {
        clear()
        var arr = _parseConfigJson(plasmoid.configuration.tasksJson)
        for (var i = 0; i < arr.length; i++)
            append(normalizeTask(arr[i]))
        var path = plasmoid.configuration.storagePath
        if (path !== "") requestFileLoad(path)
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

    function _saveJsonOnly() {
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
        plasmoid.configuration.tasksJson = JSON.stringify(doc.tasks)
        var b64 = _base64(json)
        var lastSlash = path.lastIndexOf("/")
        var dir = lastSlash === -1 ? "." : path.substring(0, lastSlash)
        var cmd = "mkdir -p " + _shellArg(dir) + " && " +
            "printf '%s' '" + b64 + "' | base64 -d > " + _shellArg(path + ".tmp") + " && " +
            "mv -f " + _shellArg(path + ".tmp") + " " + _shellArg(path)
        runShellCmd(cmd)
        if (!plasmoid.configuration.migratedToFile)
            plasmoid.configuration.migratedToFile = true
    }

    function save() {
        _saveJsonOnly()
        if (plasmoid.configuration.markdownExport) {
            var path = plasmoid.configuration.storagePath
            if (path === "") return
            var mdPath = plasmoid.configuration.markdownPath
            if (mdPath === "") {
                mdPath = path.replace(/\.json$/, ".md")
                if (mdPath === path) mdPath = path + ".md"
            }
            if (mdPath === path) return
            var md = _serializeMarkdown()
            var mdB64 = _base64(md)
            var mdLastSlash = mdPath.lastIndexOf("/")
            var mdDir = mdLastSlash === -1 ? "." : mdPath.substring(0, mdLastSlash)
            var mdCmd = "mkdir -p " + _shellArg(mdDir) + " && " +
                "printf '%s' '" + mdB64 + "' | base64 -d > " + _shellArg(mdPath + ".tmp") + " && " +
                "mv -f " + _shellArg(mdPath + ".tmp") + " " + _shellArg(mdPath)
            runShellCmd(mdCmd)
        }
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
        var addToTop = plasmoid.configuration.addToTop
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
        var t = normalizeTask(task)
        var clamped = Math.max(0, Math.min(index, count))
        insert(clamped, {
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
        save()
    }

    function deleteCompleted() {
        var changed = false
        for (var i = count - 1; i >= 0; i--) {
            if (get(i).done === true) {
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
        var path = plasmoid.configuration.storagePath
        if (path === "") {
            var dataHome = StandardPaths.writableLocation(StandardPaths.GenericDataLocation).toString()
            if (dataHome.startsWith("file://"))
                dataHome = dataHome.substring(7)
            plasmoid.configuration.storagePath = dataHome + "/kdoit/tasks.json"
        } else if (path.startsWith("file://")) {
            plasmoid.configuration.storagePath = path.substring(7)
        }
        load()
    }
}
