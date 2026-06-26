import QtQuick
import org.kde.plasma.plasmoid

ListModel {
    id: model

    function load() {
        clear()
        var raw = plasmoid.configuration.tasksJson
        var arr = []
        try {
            arr = JSON.parse(raw)
            if (!Array.isArray(arr))
                arr = []
        } catch (e) {
            arr = []
        }
        for (var i = 0; i < arr.length; i++) {
            var t = arr[i]
            append({
                title: t.title !== undefined ? t.title : "",
                done: t.done === true,
                priority: t.priority !== undefined ? t.priority : 1,
                category: (t.category !== undefined ? t.category : "").trim(),
                createdAt: t.createdAt !== undefined ? t.createdAt : "",
                dueDate: t.dueDate !== undefined ? t.dueDate : "",
                sublist: normalizeSublist(t.sublist)
            })
        }
    }

    function normalizeSublist(sub) {
        var out = []
        if (Array.isArray(sub)) {
            for (var i = 0; i < sub.length; i++) {
                out.push({
                    title: sub[i].title !== undefined ? sub[i].title : "",
                    done: sub[i].done === true
                })
            }
        } else if (sub && typeof sub.count === "number" && typeof sub.get === "function") {
            for (var j = 0; j < sub.count; j++) {
                var e = sub.get(j)
                out.push({
                    title: e.title !== undefined ? e.title : "",
                    done: e.done === true
                })
            }
        }
        return out
    }

    function save() {
        var arr = []
        for (var i = 0; i < count; i++) {
            var t = get(i)
            arr.push({
                title: t.title,
                done: t.done,
                priority: t.priority,
                category: t.category,
                createdAt: t.createdAt,
                dueDate: t.dueDate,
                sublist: normalizeSublist(t.sublist)
            })
        }
        plasmoid.configuration.tasksJson = JSON.stringify(arr)
    }

    function addTask(title, priority) {
        if (title.trim() === "")
            return
        append({
            title: title,
            done: false,
            priority: priority,
            category: "",
            createdAt: new Date().toISOString(),
            dueDate: "",
            sublist: []
        })
        save()
    }

    function removeTask(index) {
        if (index < 0 || index >= count)
            return
        remove(index)
        save()
    }

    function removeTasks(indices) {
        var sorted = indices.slice().sort(function (a, b) { return b - a })
        for (var i = 0; i < sorted.length; i++) {
            if (sorted[i] >= 0 && sorted[i] < count)
                remove(sorted[i], 1)
        }
        save()
    }

    function moveTask(from, to) {
        if (from === to)
            return
        if (from < 0 || from >= count || to < 0 || to >= count)
            return
        move(from, to, 1)
        save()
    }

    function setTaskProperty(index, key, value) {
        if (index < 0 || index >= count)
            return
        setProperty(index, key, value)
        save()
    }

    function insertTask(index, task) {
        var clamped = Math.max(0, Math.min(index, count))
        insert(clamped, {
            title: task.title,
            done: task.done,
            priority: task.priority,
            category: task.category,
            createdAt: task.createdAt,
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

    Component.onCompleted: load()
}
