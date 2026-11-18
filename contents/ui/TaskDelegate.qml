pragma ComponentBehavior: Bound

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
    // The ListModel rows are edited in; the view's own model may be a
    // DelegateModel that filters it.
    property var sourceModel: listView ? listView.model : null
    property real gridSize: Kirigami.Units.gridUnit * 2
    property bool matched: true
    property bool dragEnabled: true
    property bool isSublistItem: false

    property bool isDragging: false
    property real dragOffsetY: 0
    property int startIndex: index
    property int targetIndex: index
    property real startMouseY: 0
    property bool _pressPending: false
    property real _pressX: 0
    property real _pressY: 0
    property real _menuOpenX: 0
    property real _menuOpenY: 0

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

    function emitTaskChanged() {
        if (typeof delegate.sourceModel.touch === "function")
            delegate.sourceModel.touch(delegate.index)
        delegate.taskChanged()
    }

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
        var today = root.todayDate
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
        var today = root.todayDate
        var parts = dueDate.split("-")
        if (parts.length !== 3)
            return false
        var year = parseInt(parts[0])
        var month = parseInt(parts[1])
        var day = parseInt(parts[2])
        var d = new Date(year, month - 1, day)
        if (d.getFullYear() !== year || d.getMonth() !== month - 1 || d.getDate() !== day)
            return false
        return year === today.getFullYear() && month === today.getMonth() + 1 && day === today.getDate()
    }

    function sublistCount() {
        if (!sublist)
            return 0
        return (typeof sublist.count === "number") ? sublist.count : (sublist.length || 0)
    }

    function sublistItem(i) {
        return (typeof sublist.get === "function") ? sublist.get(i) : sublist[i]
    }

    function sublistDone() {
        var n = 0
        var c = sublistCount()
        for (var i = 0; i < c; i++) {
            if (sublistItem(i).done === true)
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
        var now = root.todayDate
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

    function _popupParent() {
        return Controls.Overlay.overlay || delegate.Window?.contentItem
    }

    function _capturePosition() {
        var target = _popupParent()
        if (target) {
            var pos = delegate.mapToItem(target, delegate.width / 2, delegate.height / 2)
            delegate._menuOpenX = pos.x
            delegate._menuOpenY = pos.y
        }
    }

    // The menus and dialogs below are about 80% of a row's construction cost,
    // and rows are created and destroyed as the list scrolls, so each row
    // builds them the first time it needs one.
    Loader {
        id: popups
        active: false
        sourceComponent: popupsComponent
    }

    function _popups() {
        popups.active = true
        return popups.item
    }

    function openMenu() {
        _capturePosition()
        var p = _popups()
        if (delegate.isSublistItem)
            p.sublistMenu.popup()
        else
            p.contextMenu.popup()
    }

    function openRenameDialog() {
        var p = _popups()
        p.renameField.text = delegate.title
        positionPopup(p.renameDialog)
        p.renameDialog.open()
    }

    function openCategoryDialog() {
        var p = _popups()
        p.categoryField.text = delegate.category
        positionPopup(p.categoryDialog)
        p.categoryDialog.open()
    }

    function openDateDialog() {
        var p = _popups()
        positionPopup(p.dateDialog)
        p.dateDialog.open()
    }

    function positionPopup(popup) {
        var target = _popupParent()
        if (!target) return
        var pw = popup.implicitWidth || popup.width
        var dx = delegate._menuOpenX - pw / 2
        var dy = delegate._menuOpenY + Kirigami.Units.gridUnit
        dx = Math.max(0, Math.min(dx, target.width - pw))
        var ph = popup.implicitHeight || popup.height || Kirigami.Units.gridUnit * 8
        dy = Math.max(0, Math.min(dy, target.height - ph))
        popup.x = dx
        popup.y = dy
    }

    MouseArea {
        id: rowMouseArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        preventStealing: true

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
                var raw = Math.round((delegate.startIndex * delegate.gridSize + delegate.dragOffsetY) / delegate.gridSize)
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
                if (from !== to && typeof delegate.sourceModel.moveTask === "function") {
                    delegate.sourceModel.moveTask(from, to)
                    root.clearSelection()
                }
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
        color: Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
        z: -1
    }

    Rectangle {
        visible: !delegate.isSublistItem && plasmoid.configuration.showPriority
        width: Kirigami.Units.smallSpacing
        height: parent.height
        anchors.left: parent.left
        color: delegate.priority === 2 ? Kirigami.Theme.negativeTextColor
             : delegate.priority === 1 ? Kirigami.Theme.neutralTextColor
             : Qt.alpha(Kirigami.Theme.textColor, 0.1)
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.largeSpacing
        anchors.rightMargin: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        PlasmaComponents.CheckBox {
            id: taskCheckBox
            Binding on checked {
                value: delegate.done
            }
            onToggled: {
                delegate.sourceModel.setProperty(delegate.index, "done", checked)
                delegate.emitTaskChanged()
            }
        }

        PlasmaComponents.Label {
            id: titleLabel
            text: delegate.title
            elide: Text.ElideRight
            maximumLineCount: 1
            Layout.fillWidth: true
            color: delegate.done ? Qt.alpha(Kirigami.Theme.textColor, 0.6) : Kirigami.Theme.textColor
            font.strikeout: delegate.done

            Controls.ToolTip {
                visible: titleLabel.truncated && delegate.hovered
                delay: Kirigami.Units.toolTipDelay
                text: titleLabel.text
                width: Math.min(implicitWidth, Kirigami.Units.gridUnit * 20)
            }
        }

        PlasmaComponents.Label {
            visible: delegate.sublistCount() > 0
            text: delegate.sublistDone() + "/" + delegate.sublistCount()
            color: plasmoid.configuration.countColor !== ""
                   ? plasmoid.configuration.countColor
                   : Kirigami.Theme.highlightColor
            font.pointSize: Kirigami.Theme.smallFont.pointSize

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: delegate.drillIntoSublist(delegate.index)
            }
        }

        Item {
            // Fixed-width right zone: shows cat/date when idle, edit button when hovered.
            // Using a single container with fixed width prevents the unconstrained
            // fillWidth edit button from collapsing to zero and overlapping the
            // sublist counter to its left.
            visible: !delegate.isSublistItem || delegate.hovered
            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
            Layout.alignment: Qt.AlignVCenter

            Column {
                visible: !delegate.isSublistItem && !delegate.hovered
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
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
                visible: delegate.hovered
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                icon.name: "entry-edit-symbolic"
                flat: true
                display: PlasmaComponents.AbstractButton.IconOnly
                text: i18n("Edit task")
                onClicked: {
                    delegate._capturePosition()
                    delegate.openRenameDialog()
                }
            }
        }
    }

    function toIso(d) {
        var m = (d.getMonth() + 1)
        var day = d.getDate()
        return d.getFullYear() + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
    }

    Component {
        id: popupsComponent

        Item {
            property alias contextMenu: contextMenu
            property alias sublistMenu: sublistMenu
            property alias dateDialog: dateDialog
            property alias renameDialog: renameDialog
            property alias renameField: renameField
            property alias categoryDialog: categoryDialog
            property alias categoryField: categoryField

            Controls.Menu {
                id: contextMenu

                Controls.MenuItem {
                    text: i18n("Open subtasks")
                    onTriggered: delegate.drillIntoSublist(delegate.index)
                }

                Controls.MenuSeparator {}

                Controls.Menu {
                    title: i18n("Due date")

                    Controls.MenuItem {
                        text: i18n("Today")
                        onTriggered: {
                            var d = new Date()
                            delegate.sourceModel.setProperty(delegate.index, "dueDate", delegate.toIso(d))
                            delegate.emitTaskChanged()
                        }
                    }
                    Controls.MenuItem {
                        text: i18n("Tomorrow")
                        onTriggered: {
                            var d = new Date()
                            d.setDate(d.getDate() + 1)
                            delegate.sourceModel.setProperty(delegate.index, "dueDate", delegate.toIso(d))
                            delegate.emitTaskChanged()
                        }
                    }
                    Controls.MenuItem {
                        text: i18n("Custom date...")
                        onTriggered: delegate.openDateDialog()
                    }
                    Controls.MenuItem {
                        text: i18n("Delete date")
                        onTriggered: {
                            delegate.sourceModel.setProperty(delegate.index, "dueDate", "")
                            delegate.emitTaskChanged()
                        }
                    }
                }

                Controls.Menu {
                    title: i18n("Priority")

                    Controls.MenuItem {
                        text: i18n("High")
                        onTriggered: {
                            delegate.sourceModel.setProperty(delegate.index, "priority", 2)
                            delegate.emitTaskChanged()
                        }
                    }
                    Controls.MenuItem {
                        text: i18n("Medium")
                        onTriggered: {
                            delegate.sourceModel.setProperty(delegate.index, "priority", 1)
                            delegate.emitTaskChanged()
                        }
                    }
                    Controls.MenuItem {
                        text: i18n("Low")
                        onTriggered: {
                            delegate.sourceModel.setProperty(delegate.index, "priority", 0)
                            delegate.emitTaskChanged()
                        }
                    }
                }

                Controls.Menu {
                    title: i18n("Category")

                    Controls.MenuItem {
                        text: i18n("None")
                        onTriggered: {
                            delegate.sourceModel.setProperty(delegate.index, "category", "")
                            delegate.emitTaskChanged()
                        }
                    }

                    Controls.MenuSeparator {}

                    Repeater {
                        model: root.managedCategories
                        Controls.MenuItem {
                            required property string modelData
                            text: modelData
                            onTriggered: {
                                delegate.sourceModel.setProperty(delegate.index, "category", modelData)
                                delegate.emitTaskChanged()
                            }
                        }
                    }

                    Controls.MenuSeparator {}

                    Controls.MenuItem {
                        text: i18n("Custom...")
                        onTriggered: delegate.openCategoryDialog()
                    }
                }

                Controls.MenuItem {
                    text: i18n("Rename...")
                    onTriggered: delegate.openRenameDialog()
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
                    onTriggered: delegate.openRenameDialog()
                }

                Controls.MenuItem {
                    text: i18n("Delete")
                    onTriggered: delegate.taskDeleted()
                }
            }

            Controls.Popup {
                id: dateDialog
                modal: true
                closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
                parent: delegate._popupParent()
                padding: Kirigami.Units.smallSpacing
                implicitWidth: Kirigami.Units.gridUnit * 22

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

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Heading {
                        level: 4
                        text: i18n("Custom date")
                        Layout.fillWidth: true
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
                            onValueChanged: {
                                var maxDay = new Date(yearSpin.value, monthSpin.value, 0).getDate()
                                daySpin.to = maxDay
                                if (daySpin.value > maxDay) daySpin.value = maxDay
                            }
                        }
                        PlasmaComponents.SpinBox {
                            id: yearSpin
                            from: 2000
                            to: 2100
                            onValueChanged: {
                                var maxDay = new Date(yearSpin.value, monthSpin.value, 0).getDate()
                                daySpin.to = maxDay
                                if (daySpin.value > maxDay) daySpin.value = maxDay
                            }
                        }
                    }

                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Item { Layout.fillWidth: true }
                        PlasmaComponents.Button {
                            icon.name: "dialog-cancel"
                            display: PlasmaComponents.AbstractButton.IconOnly
                            text: i18n("Cancel")
                            onClicked: dateDialog.close()
                        }
                        PlasmaComponents.Button {
                            icon.name: "dialog-ok"
                            display: PlasmaComponents.AbstractButton.IconOnly
                            text: i18n("OK")
                            onClicked: {
                                var m = monthSpin.value
                                var day = daySpin.value
                                var iso = yearSpin.value + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
                                delegate.sourceModel.setProperty(delegate.index, "dueDate", iso)
                                delegate.emitTaskChanged()
                                dateDialog.close()
                            }
                        }
                    }
                }
            }

            Controls.Popup {
                id: renameDialog
                modal: true
                closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
                parent: delegate._popupParent()
                padding: Kirigami.Units.smallSpacing
                implicitWidth: Kirigami.Units.gridUnit * 16

                onOpened: renameField.forceActiveFocus()

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Heading {
                        level: 4
                        text: i18n("Rename task")
                        Layout.fillWidth: true
                    }

                    PlasmaComponents.TextField {
                        id: renameField
                        implicitWidth: Kirigami.Units.gridUnit * 14
                        onAccepted: {
                            var text = renameField.text.trim()
                            if (text.length > 0) {
                                delegate.sourceModel.setProperty(delegate.index, "title", text)
                                delegate.emitTaskChanged()
                            }
                            renameDialog.close()
                        }
                    }

                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Item { Layout.fillWidth: true }
                        PlasmaComponents.Button {
                            icon.name: "dialog-cancel"
                            display: PlasmaComponents.AbstractButton.IconOnly
                            text: i18n("Cancel")
                            onClicked: renameDialog.close()
                        }
                        PlasmaComponents.Button {
                            icon.name: "dialog-ok"
                            display: PlasmaComponents.AbstractButton.IconOnly
                            text: i18n("OK")
                            onClicked: {
                                var text = renameField.text.trim()
                                if (text.length > 0) {
                                    delegate.sourceModel.setProperty(delegate.index, "title", text)
                                    delegate.emitTaskChanged()
                                }
                                renameDialog.close()
                            }
                        }
                    }
                }
            }

            Controls.Popup {
                id: categoryDialog
                modal: true
                closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
                parent: delegate._popupParent()
                padding: Kirigami.Units.smallSpacing
                implicitWidth: Kirigami.Units.gridUnit * 16

                onOpened: categoryField.forceActiveFocus()

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Heading {
                        level: 4
                        text: i18n("Set category")
                        Layout.fillWidth: true
                    }

                    PlasmaComponents.TextField {
                        id: categoryField
                        implicitWidth: Kirigami.Units.gridUnit * 14
                        placeholderText: i18n("Category name...")
                        onAccepted: {
                            var text = categoryField.text.trim()
                            if (text.length > 0) {
                                root.addManagedCategory(text)
                                delegate.sourceModel.setProperty(delegate.index, "category", text)
                                delegate.emitTaskChanged()
                            }
                            categoryDialog.close()
                        }
                    }

                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Item { Layout.fillWidth: true }
                        PlasmaComponents.Button {
                            icon.name: "dialog-cancel"
                            display: PlasmaComponents.AbstractButton.IconOnly
                            text: i18n("Cancel")
                            onClicked: categoryDialog.close()
                        }
                        PlasmaComponents.Button {
                            icon.name: "dialog-ok"
                            display: PlasmaComponents.AbstractButton.IconOnly
                            text: i18n("OK")
                            onClicked: {
                                var text = categoryField.text.trim()
                                if (text.length > 0) {
                                    root.addManagedCategory(text)
                                    delegate.sourceModel.setProperty(delegate.index, "category", text)
                                    delegate.emitTaskChanged()
                                }
                                categoryDialog.close()
                            }
                        }
                    }
                }
            }
        }
    }
}
