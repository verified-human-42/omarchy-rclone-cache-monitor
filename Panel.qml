import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// rclone Cache Monitor: a read-only view of every rclone FUSE mount on the machine.
// The bundled rclone-cache-stats script prints cumulative counters as JSON; this widget diffs two
// consecutive snapshots into rates. Rates are tracked per rclone process, because one `rclone rcd`
// can serve several mounts and its network and CPU counters are shared between them.
Panel {
  id: root
  moduleName: "io.github.verified-human-42.rclone-cache-monitor"
  ipcTarget: "io.github.verified-human-42.rclone-cache-monitor"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string collector: decodeURIComponent(String(Qt.resolvedUrl("rclone-cache-stats")).replace(/^file:\/\//, ""))
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property int pollSec: Math.max(1, Math.min(30, Number(setting("pollSec", 3)) || 3))
  readonly property bool showRate: setting("showRate", true) !== false
  readonly property bool vertical: root.bar ? root.bar.vertical : false
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)

  property var mounts: []          // enriched records, one per mount point
  property var prevByPid: ({})     // last raw counters per rclone pid
  property bool collectorFailed: false
  property real totalCache: 0
  property real totalNet: 0
  property int totalUploading: 0
  property bool problem: false

  readonly property bool busy: totalNet >= 100 * 1024 || totalUploading > 0

  function mb(bytesPerSec) { return Commons.I18n.formatNumber(bytesPerSec / 1048576, 1) }
  function gb(bytes) { return Commons.I18n.formatNumber(bytes / 1073741824, 1) }
  function clip(s, n) { s = String(s === undefined || s === null ? "" : s); return s.length > n ? s.slice(0, n - 1) + "…" : s }
  function tilde(p) {
    p = String(p || "")
    return root.home && (p === root.home || p.indexOf(root.home + "/") === 0) ? "~" + p.slice(root.home.length) : p
  }
  function num(v) { const n = Number(v); return isFinite(n) ? n : 0 }

  function parse(text) {
    let snap = null
    try { snap = JSON.parse(String(text || "")) } catch (e) { snap = null }
    if (!snap || !Array.isArray(snap.mounts)) { collectorFailed = true; return }
    collectorFailed = false

    const ts = num(snap.ts), hz = num(snap.hz) || 100
    const ratesByPid = {}, nextPrev = {}
    for (const m of snap.mounts.slice(0, 32)) {
      if (m.pid === null || m.pid === undefined || ratesByPid[m.pid]) continue
      const cur = { ts: ts, read: num(m.read_bytes), cpu: num(m.cpu_ticks), net: m.stats === "ok" ? num(m.net_bytes) : -1 }
      nextPrev[m.pid] = cur
      const p = root.prevByPid[m.pid]
      const r = { cache: 0, net: 0, read: 0, cpu: 0 }
      const dt = p ? cur.ts - p.ts : 0
      // A negative delta means the process restarted with fresh counters: report zero once.
      if (p && dt > 0 && cur.read >= p.read && cur.cpu >= p.cpu) {
        r.read = (cur.read - p.read) / dt
        r.cpu = (cur.cpu - p.cpu) / hz / dt * 100
        if (cur.net >= 0 && p.net >= 0 && cur.net >= p.net) {
          r.net = (cur.net - p.net) / dt
          r.cache = Math.max(0, r.read - r.net)
        }
      }
      ratesByPid[m.pid] = r
    }
    root.prevByPid = nextPrev

    const pidCount = {}
    for (const m of snap.mounts) if (m.pid !== null && m.pid !== undefined) pidCount[m.pid] = (pidCount[m.pid] || 0) + 1

    let cache = 0, net = 0, uploading = 0, bad = false
    const counted = {}
    const out = []
    for (const m of snap.mounts.slice(0, 32)) {
      const r = ratesByPid[m.pid] || { cache: 0, net: 0, read: 0, cpu: 0 }
      const rec = Object.assign({}, m, {
        cacheRate: r.cache, netRate: r.net, readRate: r.read, cpuPct: r.cpu,
        shared: (pidCount[m.pid] || 0) > 1,
        uploading: num(m.uploads_queued) + num(m.uploads_in_progress)
      })
      if (m.pid !== null && m.pid !== undefined && !counted[m.pid]) { counted[m.pid] = true; cache += r.cache; net += r.net }
      uploading += rec.uploading
      if (m.stats === "no-process" || m.stats === "unreachable" || num(m.cache_errored) > 0 || m.out_of_space === true) bad = true
      out.push(rec)
    }
    root.mounts = out
    root.totalCache = cache
    root.totalNet = net
    root.totalUploading = uploading
    root.problem = bad
  }

  function refresh() {
    if (proc.running) return
    proc.command = root.opened ? ["bash", root.collector, "--readers"] : ["bash", root.collector]
    proc.running = true
  }

  Process {
    id: proc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parse(text) }
    onExited: function(exitCode) { if (exitCode !== 0) root.collectorFailed = true }
  }

  Timer {
    interval: root.pollSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    dimmed: root.mounts.length === 0 && !root.collectorFailed
    active: root.problem || root.collectorFailed
    labelText: root.showRate && !root.vertical && root.busy
      ? (root.totalNet >= 100 * 1024 ? strings.t("rate").arg(root.mb(root.totalNet)) : "↑" + root.totalUploading)
      : ""
    slotSize: Style.bar.iconSlot * (labelText !== "" ? 3 : 1)
    tooltipText: root.mounts.length === 0 ? strings.t("tooltipNone")
      : root.problem ? strings.t("tooltipProblem")
      : strings.t("tooltip").arg(root.mb(root.totalCache)).arg(root.mb(root.totalNet)).arg(root.totalUploading)
    onPressed: function(b) { root.toggle() }
  }

  component Line: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)
    Text {
      id: labelText
      anchors.left: parent.left
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(12)
      textFormat: Text.PlainText
      text: parent.label
      elide: Text.ElideRight
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Text {
      id: valueText
      anchors.right: parent.right
      textFormat: Text.PlainText
      text: parent.value
      color: root.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.features: { "tnum": 1 }
    }
  }

  component Note: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    color: root.dim
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  component ListText: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    elide: Text.ElideMiddle
    color: root.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(d) { root.switchPanel(d) }

      // The panel caps its height to the screen; many mounts scroll instead of being cut off.
      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

      Column {
        id: column
        width: flick.width
        spacing: Style.space(8)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("title")
          color: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Note { visible: root.collectorFailed; text: strings.t("collectorFailed"); color: Color.urgent }
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: !root.collectorFailed && root.mounts.length === 0
          ListText { text: strings.t("noMounts") }
          Note { text: strings.t("noMountsHint") }
        }

        Repeater {
          model: root.mounts

          Column {
            id: card
            required property var modelData
            required property int index
            readonly property var m: modelData
            readonly property bool ok: m.stats === "ok"
            width: column.width
            spacing: Style.space(6)

            PanelSeparator { width: parent.width; foreground: root.fg; visible: card.index > 0 }

            Item {
              width: parent.width
              implicitHeight: Math.max(titleText.implicitHeight, openButton.implicitHeight)
              Text {
                id: titleText
                anchors.left: parent.left
                anchors.right: openButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.clip(card.m.source, 60) + "  →  " + root.clip(root.tilde(card.m.mountpoint), 80)
                elide: Text.ElideMiddle
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Button {
                id: openButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("openFolder")
                foreground: root.fg
                onClicked: root.bar && root.bar.run("xdg-open " + Util.shellQuote(card.m.mountpoint))
              }
            }

            // Problems first, so they're the first thing read.
            Note { visible: card.m.stats === "no-process"; text: strings.t("noProcess") + "\n" + strings.t("noProcessHint"); color: Color.urgent }
            Note { visible: card.m.stats === "unreachable"; text: strings.t("statsUnreachable"); color: Color.urgent }
            Note { visible: card.m.stats === "auth"; text: strings.t("statsAuth") }
            Note { visible: card.m.stats === "off"; text: strings.t("statsOff") + "\n" + strings.t("statsOffHint") }
            Note { visible: card.m.out_of_space === true; text: strings.t("outOfSpace"); color: Color.urgent }

            Line { visible: card.ok; label: strings.t("fromCache"); value: strings.t("rate").arg(root.mb(card.m.cacheRate)) }
            Line { visible: card.ok; label: strings.t("fromNetwork"); value: strings.t("rate").arg(root.mb(card.m.netRate)) }
            Line {
              visible: card.m.stats !== "ok" && card.m.pid !== null && card.m.pid !== undefined
              label: strings.t("reads"); value: strings.t("rate").arg(root.mb(card.m.readRate))
            }
            Line {
              visible: card.ok
              label: strings.t("uploads")
              value: strings.t("uploadsValue").arg(root.num(card.m.uploads_queued)).arg(root.num(card.m.uploads_in_progress))
            }

            Note { visible: card.ok && card.m.cache_mode === 0; text: strings.t("cacheOff") }
            Line {
              visible: card.ok && card.m.cache_mode !== 0
              label: strings.t("cache")
              value: root.num(card.m.cache_max_bytes) > 0
                ? strings.t("cacheValue").arg(root.gb(card.m.cache_bytes)).arg(root.gb(card.m.cache_max_bytes))
                : strings.t("cacheValueNoLimit").arg(root.gb(card.m.cache_bytes))
            }
            Rectangle {
              visible: card.ok && card.m.cache_mode !== 0 && root.num(card.m.cache_max_bytes) > 0
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
              Rectangle {
                readonly property real frac: Math.min(1, root.num(card.m.cache_bytes) / Math.max(1, root.num(card.m.cache_max_bytes)))
                height: parent.height
                radius: parent.radius
                width: parent.width * frac
                color: frac > 0.9 ? Color.urgent : Color.accent
              }
            }
            Note {
              visible: card.ok && card.m.cache_mode !== 0
              text: strings.tn("cacheFiles", root.num(card.m.cache_files)).arg(Commons.I18n.formatNumber(root.num(card.m.cache_files)))
                + (root.num(card.m.cache_errored) > 0
                   ? " · " + strings.tn("cacheErrored", root.num(card.m.cache_errored)).arg(root.num(card.m.cache_errored)) : "")
            }

            Line {
              visible: card.m.pid !== null && card.m.pid !== undefined
              label: strings.t("cpu"); value: strings.t("cpuValue").arg(Commons.I18n.formatNumber(card.m.cpuPct, 1))
            }
            Note { visible: card.m.shared === true; text: strings.t("sharedProcess") }

            // Queue and readers only take space when there's something to list.
            PanelSectionHeader { visible: card.ok && (card.m.queue || []).length > 0; text: strings.t("waiting"); foreground: root.fg }
            Repeater {
              model: card.ok ? (card.m.queue || []).slice(0, 5) : []
              ListText { required property var modelData; text: root.clip(modelData, 200) }
            }

            PanelSectionHeader { visible: (card.m.readers || []).length > 0; text: strings.t("readers"); foreground: root.fg }
            Repeater {
              model: (card.m.readers || []).slice(0, 5)
              Line {
                required property var modelData
                label: root.clip(modelData.app, 40)
                value: strings.tn("readerFiles", root.num(modelData.files)).arg(Commons.I18n.formatNumber(root.num(modelData.files)))
              }
            }
          }
        }
      }
      }
    }
  }
}
