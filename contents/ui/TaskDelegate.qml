import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami as Kirigami

PlasmaComponents.ItemDelegate {
    id: delegate

    required property int index
    required property string title
    required property bool done
    required property int priority
    required property string category
    required property string dueDate
    required property var sublist

    property ListView listView: ListView.view
    property real gridSize: 40
    property bool matched: true
    property bool dragEnabled: true
    property bool isSublistItem: false

    property bool isDragging: false
    property bool selected: false
    property real dragOffsetY: 0
    property int startIndex: index
    property int targetIndex: index
    property real startMouseY: 0
    property bool _pressPending: false
    property real _pressX: 0
    property real _pressY: 0

    property bool shouldMakeSpace: {
        if (!listView || !listView.currentDragActive || isDragging)
            return false
        var src = listView.dragSourceIndex
        var tgt = listView.dropTargetIndex
        if (src === tgt)
            return false
        if (src < tgt)
            return index > src && index <= tgt
        return index < src && index >= tgt
    }

    property int spaceDirection: {
        if (!listView || !listView.currentDragActive)
            return 0
        var src = listView.dragSourceIndex
        return src < listView.dropTargetIndex ? -1 : 1
    }

    signal taskChanged()
    signal taskDeleted()
    signal drillIntoSublist(int taskIndex)
    signal dragStarted(int index)
    signal dropTargetChanged(int index)
    signal dropping()

    width: listView ? listView.width : implicitWidth
    height: matched ? gridSize : 0
    visible: matched
    enabled: matched
    clip: true
    hoverEnabled: true
    z: isDragging ? 100 : 1

    function isOverdue() {
        if (done || dueDate === "")
            return false
        var today = new Date()
        var t = new Date(today.getFullYear(), today.getMonth(), today.getDate())
        var parts = dueDate.split("-")
        if (parts.length !== 3)
            return false
        var year = parseInt(parts[0])
        var month = parseInt(parts[1])
        var day = parseInt(parts[2])
        var d = new Date(year, month - 1, day)
        if (d.getFullYear() !== year || d.getMonth() !== month - 1 || d.getDate() !== day)
            return false
        return d < t
    }

    function isToday() {
        if (dueDate === "")
            return false
        var today = new Date()
        var parts = dueDate.split("-")
        if (parts.length !== 3)
            return false
        var year = parseInt(parts[0])
        var month = parseInt(parts[1])
        var day = parseInt(parts[2])
        return year === today.getFullYear() && month === today.getMonth() + 1 && day === today.getDate()
    }

    function sublistDone() {
        var n = 0
        for (var i = 0; i < sublist.length; i++) {
            if (sublist[i].done === true)
                n++
        }
        return n
    }

    function formatDate(d) {
        var parts = d.split("-")
        if (parts.length !== 3)
            return d
        var numeric = parts[2] + "/" + parts[1]
        if (!plasmoid.configuration.verboseDates)
            return numeric
        var year = parseInt(parts[0])
        var month = parseInt(parts[1])
        var day = parseInt(parts[2])
        var due = new Date(year, month - 1, day)
        if (due.getFullYear() !== year || due.getMonth() !== month - 1 || due.getDate() !== day)
            return numeric
        var now = new Date()
        var today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        var diff = Math.round((due - today) / 86400000)
        if (diff === 0)
            return i18n("Today")
        if (diff === 1)
            return i18n("Tomorrow")
        if (diff === -1)
            return i18n("Yesterday")
        return numeric
    }

    function resetTransform() {
        isDragging = false
        dragOffsetY = 0
    }

    transform: Translate {
        id: translate
        y: delegate.isDragging ? delegate.dragOffsetY
                               : (delegate.shouldMakeSpace ? delegate.gridSize * delegate.spaceDirection : 0)
        Behavior on y {
            enabled: !delegate.isDragging
            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
        }
    }

    Connections {
        target: delegate.listView
        function onResetAllTransforms() {
            delegate.resetTransform()
        }
    }

    function openMenu() {
        if (delegate.isSublistItem)
            sublistMenu.popup()
        else
            contextMenu.popup()
    }

    MouseArea {
        id: rowMouseArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        preventStealing: true
        enabled: !delegate.isSublistItem || true

        onPressed: function (mouse) {
            if (mouse.button === Qt.RightButton)
                return
            delegate._pressX = mouse.x
            delegate._pressY = mouse.y
            delegate._pressPending = true
        }

        onPositionChanged: function (mouse) {
            if (delegate.isDragging) {
                var currentY = mapToItem(delegate.listView, 0, mouse.y).y
                delegate.dragOffsetY = currentY - delegate.startMouseY
                var raw = Math.round((delegate.index * delegate.gridSize + delegate.dragOffsetY) / delegate.gridSize)
                var clamped = Math.max(0, Math.min(raw, delegate.listView.count - 1))
                delegate.targetIndex = clamped
                delegate.dropTargetChanged(clamped)
                return
            }
            if (!delegate._pressPending)
                return
            var dx = mouse.x - delegate._pressX
            var dy = mouse.y - delegate._pressY
            if (Math.abs(dx) > Kirigami.Units.gridUnit || Math.abs(dy) > Kirigami.Units.gridUnit) {
                delegate._pressPending = false
                if (!delegate.dragEnabled)
                    return
                delegate.startIndex = delegate.index
                delegate.targetIndex = delegate.index
                delegate.startMouseY = mapToItem(delegate.listView, 0, delegate._pressY).y
                delegate.isDragging = true
                delegate.dragStarted(delegate.index)
            }
        }

        onReleased: function (mouse) {
            if (mouse.button === Qt.RightButton) {
                delegate.openMenu()
                return
            }
            if (delegate.isDragging) {
                var from = delegate.startIndex
                var to = delegate.targetIndex
                delegate.dropping()
                delegate.isDragging = false
                delegate.dragOffsetY = 0
                if (from !== to && typeof delegate.listView.model.moveTask === "function")
                    delegate.listView.model.moveTask(from, to)
            } else if (delegate._pressPending) {
                if (mouse.modifiers & Qt.ControlModifier) {
                    root.toggleSelect(delegate.index)
                } else if (mouse.modifiers & Qt.ShiftModifier) {
                    root.rangeSelect(delegate.index)
                } else {
                    root.selectOnly(delegate.index)
                }
            }
            delegate._pressPending = false
        }

        onCanceled: {
            delegate._pressPending = false
            if (delegate.isDragging) {
                delegate.dropping()
                delegate.isDragging = false
                delegate.dragOffsetY = 0
            }
        }
    }

    Rectangle {
        visible: root.selectedIndices[delegate.index] === true
        anchors.fill: parent
        color: Kirigami.Theme.highlightColor
        opacity: 0.15
        z: -1
    }

    Rectangle {
        visible: !delegate.isSublistItem
        width: 3
        height: parent.height
        anchors.left: parent.left
        color: delegate.priority === 2 ? Kirigami.Theme.negativeTextColor
             : delegate.priority === 1 ? Kirigami.Theme.neutralTextColor
             : Qt.alpha(Kirigami.Theme.textColor, 0.1)
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.largeSpacing
        anchors.rightMargin: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.largeSpacing

        PlasmaComponents.CheckBox {
            id: taskCheckBox
            Binding on checked {
                value: delegate.done
            }
            onToggled: {
                delegate.listView.model.setProperty(delegate.index, "done", checked)
                delegate.taskChanged()
            }
        }

        PlasmaComponents.Label {
            text: delegate.title
            elide: Text.ElideRight
            maximumLineCount: 1
            Layout.fillWidth: true
            Layout.maximumWidth: delegate.width - Kirigami.Units.gridUnit * 9
            opacity: delegate.done ? 0.6 : 1
            font.strikeout: delegate.done
        }

        PlasmaComponents.Label {
            visible: delegate.sublist.length > 0
            text: delegate.sublistDone() + "/" + delegate.sublist.length
            color: Kirigami.Theme.highlightColor
            font.pointSize: Kirigami.Theme.smallFont.pointSize

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: delegate.drillIntoSublist(delegate.index)
            }
        }

        Column {
            visible: !delegate.isSublistItem
            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
            Layout.alignment: Qt.AlignVCenter
            spacing: 0

            PlasmaComponents.Label {
                anchors.right: parent.right
                visible: delegate.category !== ""
                text: "#" + delegate.category
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                color: Kirigami.Theme.disabledTextColor
            }

            PlasmaComponents.Label {
                anchors.right: parent.right
                visible: delegate.dueDate !== ""
                text: delegate.formatDate(delegate.dueDate)
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.bold: delegate.isOverdue() || delegate.isToday()
                color: delegate.isOverdue() ? Kirigami.Theme.negativeTextColor
                     : delegate.isToday() ? Kirigami.Theme.neutralTextColor
                     : Kirigami.Theme.textColor
            }
        }

        PlasmaComponents.Button {
            icon.name: "entry-edit-symbolic"
            flat: true
            display: PlasmaComponents.AbstractButton.IconOnly
            text: i18n("Edit task")
            opacity: delegate.hovered ? 1 : 0
            Layout.preferredWidth: implicitWidth
            Behavior on opacity { NumberAnimation { duration: 120 } }
            onClicked: delegate.openMenu()
        }
    }

    Controls.Menu {
        id: contextMenu

        Controls.Menu {
            title: i18n("Due date")

            Controls.MenuItem {
                text: i18n("Today")
                onTriggered: {
                    var d = new Date()
                    delegate.listView.model.setProperty(delegate.index, "dueDate", delegate.toIso(d))
                    delegate.taskChanged()
                }
            }
            Controls.MenuItem {
                text: i18n("Tomorrow")
                onTriggered: {
                    var d = new Date()
                    d.setDate(d.getDate() + 1)
                    delegate.listView.model.setProperty(delegate.index, "dueDate", delegate.toIso(d))
                    delegate.taskChanged()
                }
            }
            Controls.MenuItem {
                text: i18n("Custom date...")
                onTriggered: dateDialog.open()
            }
            Controls.MenuItem {
                text: i18n("Delete date")
                onTriggered: {
                    delegate.listView.model.setProperty(delegate.index, "dueDate", "")
                    delegate.taskChanged()
                }
            }
        }

        Controls.Menu {
            title: i18n("Priority")

            Controls.MenuItem {
                text: i18n("High")
                onTriggered: {
                    delegate.listView.model.setProperty(delegate.index, "priority", 2)
                    delegate.taskChanged()
                }
            }
            Controls.MenuItem {
                text: i18n("Medium")
                onTriggered: {
                    delegate.listView.model.setProperty(delegate.index, "priority", 1)
                    delegate.taskChanged()
                }
            }
            Controls.MenuItem {
                text: i18n("Low")
                onTriggered: {
                    delegate.listView.model.setProperty(delegate.index, "priority", 0)
                    delegate.taskChanged()
                }
            }
        }

        Controls.Menu {
            title: i18n("Category")

            Controls.MenuItem {
                text: i18n("None")
                onTriggered: {
                    delegate.listView.model.setProperty(delegate.index, "category", "")
                    delegate.taskChanged()
                }
            }

            Controls.MenuSeparator {}

            Repeater {
                model: root.presetCategories
                Controls.MenuItem {
                    required property var modelData
                    text: modelData.label
                    onTriggered: {
                        delegate.listView.model.setProperty(delegate.index, "category", modelData.key)
                        delegate.taskChanged()
                    }
                }
            }

            Controls.MenuSeparator {}

            Controls.MenuItem {
                text: i18n("Custom...")
                onTriggered: {
                    categoryField.text = delegate.category
                    categoryDialog.open()
                }
            }
        }

        Controls.MenuItem {
            text: i18n("Rename...")
            onTriggered: {
                renameField.text = delegate.title
                renameDialog.open()
            }
        }

        Controls.MenuSeparator {}

        Controls.MenuItem {
            text: i18n("Delete")
            onTriggered: delegate.taskDeleted()
        }
    }

    Controls.Menu {
        id: sublistMenu

        Controls.MenuItem {
            text: i18n("Rename...")
            onTriggered: {
                renameField.text = delegate.title
                renameDialog.open()
            }
        }

        Controls.MenuItem {
            text: i18n("Delete")
            onTriggered: delegate.taskDeleted()
        }
    }

    function toIso(d) {
        var m = (d.getMonth() + 1)
        var day = d.getDate()
        return d.getFullYear() + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
    }

    Controls.Dialog {
        id: dateDialog
        title: i18n("Custom date")
        modal: true
        standardButtons: Controls.Dialog.Ok | Controls.Dialog.Cancel
        anchors.centerIn: Controls.Overlay.overlay

        onOpened: {
            var parts = delegate.dueDate.split("-")
            var now = new Date()
            if (parts.length === 3) {
                yearSpin.value = parseInt(parts[0])
                monthSpin.value = parseInt(parts[1])
                daySpin.value = parseInt(parts[2])
            } else {
                yearSpin.value = now.getFullYear()
                monthSpin.value = now.getMonth() + 1
                daySpin.value = now.getDate()
            }
        }

        onAccepted: {
            var m = monthSpin.value
            var day = daySpin.value
            var iso = yearSpin.value + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
            delegate.listView.model.setProperty(delegate.index, "dueDate", iso)
            delegate.taskChanged()
        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.SpinBox {
                id: daySpin
                from: 1
                to: 31
            }
            PlasmaComponents.SpinBox {
                id: monthSpin
                from: 1
                to: 12
            }
            PlasmaComponents.SpinBox {
                id: yearSpin
                from: 2000
                to: 2100
            }
        }
    }

    Controls.Dialog {
        id: renameDialog
        title: i18n("Rename task")
        modal: true
        standardButtons: Controls.Dialog.Ok | Controls.Dialog.Cancel
        anchors.centerIn: Controls.Overlay.overlay

        onAccepted: {
            var text = renameField.text.trim()
            if (text.length > 0) {
                delegate.listView.model.setProperty(delegate.index, "title", text)
                delegate.taskChanged()
            }
        }

        PlasmaComponents.TextField {
            id: renameField
            implicitWidth: Kirigami.Units.gridUnit * 14
            onAccepted: renameDialog.accept()
        }
    }

    Controls.Dialog {
        id: categoryDialog
        title: i18n("Set category")
        modal: true
        standardButtons: Controls.Dialog.Ok | Controls.Dialog.Cancel
        anchors.centerIn: Controls.Overlay.overlay

        onAccepted: {
            var text = categoryField.text.trim()
            if (text.length === 0)
                return
            delegate.listView.model.setProperty(delegate.index, "category", text)
            delegate.taskChanged()
        }

        PlasmaComponents.TextField {
            id: categoryField
            implicitWidth: Kirigami.Units.gridUnit * 14
            placeholderText: i18n("Category name...")
            onAccepted: categoryDialog.accept()
        }
    }
}
