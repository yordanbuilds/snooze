import QtQuick
import "../../Model.mjs" as Model

// Runs Model's logic inside the real QML engine (the one Quickshell embeds).
// Node parses newer JavaScript than Qt does, so `node --test` alone cannot
// catch syntax that would make the plugin silently fail to load. Run via
// tests/qml-smoke.sh.
Item {
  Component.onCompleted: {
    const failures = []
    const check = (cond, msg) => { if (!cond) failures.push(msg) }

    const sites = Model.expandSites(["x.com", "m.youtube.com", "x.com"])
    check(sites.join(",") === "x.com,www.x.com,m.youtube.com", "expandSites www + dedupe")
    check(Model.expandSites(["https://X.com/feed", "localhost"]).join(",") === "x.com,www.x.com",
          "expandSites normalizes and drops invalid")

    check(Model.parseDuration("30m") === 30, "parseDuration 30m")
    check(Model.parseDuration("2h") === 120, "parseDuration 2h")
    check(Model.parseDuration("1h30m") === 90, "parseDuration 1h30m")
    check(Model.parseDuration("0m") === null, "parseDuration 0m is null")
    check(Model.parseDuration("soon") === null, "parseDuration junk is null")

    check(Model.formatRemaining(null) === "∞", "formatRemaining null")
    check(Model.formatRemaining(4980) === "1h 23m", "formatRemaining 1h 23m")
    check(Model.formatRemaining(59) === "1m", "formatRemaining rounds up")
    check(Model.formatRemaining(0) === "0m", "formatRemaining zero")

    const base = "127.0.0.1 localhost\n::1 localhost\n"
    const withBlock = Model.applyBlock(base, 1755350400, ["x.com", "www.x.com"])
    check(withBlock.includes("# >>> snooze >>> until=1755350400"), "applyBlock writes the marker")
    check(withBlock.includes("0.0.0.0 x.com"), "applyBlock writes the sinkhole line")

    const parsed = Model.parseHosts(withBlock)
    check(parsed.until === 1755350400, "parseHosts reads until")
    check(parsed.domains.join(",") === "x.com,www.x.com", "parseHosts reads domains")
    check(parsed.rest.includes("127.0.0.1 localhost"), "parseHosts keeps foreign content")

    const again = Model.applyBlock(withBlock, 99, ["y.com"])
    check(!again.includes("\n\n\n"), "re-apply does not grow blank lines")
    check(Model.parseHosts(again).domains.length === 1, "re-apply replaces the domains")
    check(Model.parseHosts("127.0.0.1 localhost\n").until === null, "no block means until null")

    check(Model.validateGroups({ version: 1, groups: [{ id: "a", name: "A", sites: ["x.com"] }] }),
          "validateGroups accepts a well-formed file")
    check(!Model.validateGroups({ version: 1, groups: [{ id: "a" }] }),
          "validateGroups rejects a group without a name")

    if (failures.length > 0) {
      console.error("SMOKE FAIL: " + failures.join("; "))
      Qt.exit(1)
    } else {
      console.log("SMOKE OK")
      Qt.quit()
    }
  }
}
