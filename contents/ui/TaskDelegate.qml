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
    property int priority: model.priority !== undefined ? model.priority : 0
    property string category: model.category !== undefined ? model.category : ""
    property string dueDate: model.dueDate !== undefined ? model.dueDate : ""
    property var sublist: model.sublist !== undefined ? model.sublist : []

    property ListView listView: ListView.view
    property real gridSize: 52
    property bool matched: true
    property bool dragEnabled: true
    property bool isSublistItem: false

    property bool isDragging: false
    property real dragOffsetY: 0
    property int startIndex: index
    property int targetIndex: index
    property real startMouseY: 0

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
        var d = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]))
        return d < t
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
        return parts[2] + "/" + parts[1]
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

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: contextMenu.popup()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.smallSpacing
        anchors.rightMargin: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label {
            id: dragHandle
            text: "⋮⋮"
            visible: delegate.dragEnabled
            opacity: delegate.hovered || delegate.isDragging ? 0.7 : 0
            Layout.preferredWidth: delegate.dragEnabled ? Kirigami.Units.iconSizes.small : 0
            horizontalAlignment: Text.AlignHCenter
            Behavior on opacity { NumberAnimation { duration: 120 } }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeVerCursor
                preventStealing: true
                enabled: delegate.dragEnabled

                onPressed: function (mouse) {
                    delegate.startIndex = delegate.index
                    delegate.targetIndex = delegate.index
                    delegate.startMouseY = mapToItem(delegate.listView, 0, mouse.y).y
                    delegate.isDragging = true
                    delegate.dragStarted(delegate.index)
                }

                onPositionChanged: function (mouse) {
                    if (!delegate.isDragging)
                        return
                    var currentY = mapToItem(delegate.listView, 0, mouse.y).y
                    delegate.dragOffsetY = currentY - delegate.startMouseY
                    var raw = Math.round((delegate.index * delegate.gridSize + delegate.dragOffsetY) / delegate.gridSize)
                    var clamped = Math.max(0, Math.min(raw, delegate.listView.count - 1))
                    delegate.targetIndex = clamped
                    delegate.dropTargetChanged(clamped)
                }

                onReleased: {
                    if (!delegate.isDragging)
                        return
                    var from = delegate.startIndex
                    var to = delegate.targetIndex
                    delegate.dropping()
                    delegate.isDragging = false
                    delegate.dragOffsetY = 0
                    if (from !== to)
                        delegate.listView.model.moveTask(from, to)
                }
            }
        }

        PlasmaComponents.CheckBox {
            Binding on checked {
                value: delegate.done
            }
            onToggled: {
                delegate.listView.model.setProperty(delegate.index, "done", checked)
                delegate.taskChanged()
            }
        }

        Rectangle {
            visible: !delegate.isSublistItem
            implicitWidth: 8
            implicitHeight: 8
            radius: 4
            Layout.alignment: Qt.AlignVCenter
            color: delegate.priority === 2 ? Kirigami.Theme.negativeTextColor
                 : delegate.priority === 1 ? Kirigami.Theme.neutralTextColor
                 : Kirigami.Theme.positiveTextColor
        }

        PlasmaComponents.Label {
            text: delegate.title
            elide: Text.ElideRight
            Layout.fillWidth: true
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

        PlasmaComponents.Label {
            visible: delegate.dueDate !== ""
            text: delegate.formatDate(delegate.dueDate)
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            font.bold: delegate.isOverdue()
            color: delegate.isOverdue() ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor
        }

        PlasmaComponents.Button {
            icon.name: "entry-edit-symbolic"
            flat: true
            display: PlasmaComponents.AbstractButton.IconOnly
            text: i18n("Edit task")
            opacity: delegate.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }
            onClicked: contextMenu.popup()
        }
    }

    Controls.Menu {
        id: contextMenu
        popupType: Controls.Popup.Window

        Controls.Menu {
            title: i18n("Due date")
            visible: !delegate.isSublistItem

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
            visible: !delegate.isSublistItem

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
}
