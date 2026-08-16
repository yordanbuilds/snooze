import { test } from "node:test";
import assert from "node:assert/strict";
import * as Model from "../Model.mjs";

test("isValidDomain accepts real domains, rejects junk", () => {
  assert.ok(Model.isValidDomain("facebook.com"));
  assert.ok(Model.isValidDomain("m.youtube.com"));
  assert.ok(!Model.isValidDomain("localhost"));        // one label
  assert.ok(!Model.isValidDomain("Face book.com"));    // space, uppercase
  assert.ok(!Model.isValidDomain("-bad.com"));
  assert.ok(!Model.isValidDomain("a..com"));
  assert.ok(!Model.isValidDomain("0.0.0.0 evil.com")); // injection attempt
});

test("isValidDomain enforces the length limits", () => {
  const label63 = "a".repeat(63);
  assert.ok(Model.isValidDomain(label63 + ".com"));
  assert.ok(!Model.isValidDomain("a".repeat(64) + ".com"));
  const long = (label63 + ".").repeat(4) + "com"; // 259 chars
  assert.ok(!Model.isValidDomain(long));
  assert.ok(!Model.isValidDomain(""));
  assert.ok(!Model.isValidDomain(null));
});

test("normalizeSite forgives pasted URLs", () => {
  assert.equal(Model.normalizeSite("https://WWW.YouTube.com/watch?v=x"), "www.youtube.com");
  assert.equal(Model.normalizeSite("  x.com/home  "), "x.com");
  assert.equal(Model.normalizeSite("example.com:8080"), "example.com");
});

test("normalizeSite strips a trailing dot and a bare fragment", () => {
  assert.equal(Model.normalizeSite("example.com."), "example.com");
  assert.equal(Model.normalizeSite("EXAMPLE.com#top"), "example.com");
  assert.equal(Model.normalizeSite("http://reddit.com"), "reddit.com");
});

test("expandSites adds www for two-label domains only, dedupes", () => {
  assert.deepEqual(Model.expandSites(["x.com", "m.youtube.com", "x.com"]),
    ["x.com", "www.x.com", "m.youtube.com"]);
});

test("expandSites normalizes input and drops what stays invalid", () => {
  assert.deepEqual(Model.expandSites(["https://X.com/feed", "localhost", "0.0.0.0 evil.com", "  "]),
    ["x.com", "www.x.com"]);
  assert.deepEqual(Model.expandSites([]), []);
});

test("expandSites keeps an explicit www out of the duplicate list", () => {
  assert.deepEqual(Model.expandSites(["www.x.com", "x.com"]),
    ["www.x.com", "x.com"]);
});

test("parseDuration", () => {
  assert.equal(Model.parseDuration("30m"), 30);
  assert.equal(Model.parseDuration("2h"), 120);
  assert.equal(Model.parseDuration("1h30m"), 90);
  assert.equal(Model.parseDuration("0m"), null);
  assert.equal(Model.parseDuration("soon"), null);
});

test("parseDuration ignores surrounding space and rejects partial junk", () => {
  assert.equal(Model.parseDuration("  45m  "), 45);
  assert.equal(Model.parseDuration(""), null);
  assert.equal(Model.parseDuration("30"), null);
  assert.equal(Model.parseDuration("1h 30m"), null);
  assert.equal(Model.parseDuration("30m1h"), null);
});

test("formatRemaining", () => {
  assert.equal(Model.formatRemaining(null), "∞");
  assert.equal(Model.formatRemaining(4980), "1h 23m");
  assert.equal(Model.formatRemaining(59), "1m");
  assert.equal(Model.formatRemaining(0), "0m");
});

test("formatRemaining rounds minutes up and carries into hours", () => {
  assert.equal(Model.formatRemaining(undefined), "∞");
  assert.equal(Model.formatRemaining(-10), "0m");
  assert.equal(Model.formatRemaining(3541), "1h 0m");   // 59m1s rounds up to 60m
  assert.equal(Model.formatRemaining(3600), "1h 0m");
  assert.equal(Model.formatRemaining(7140), "1h 59m");
});

test("constants are the on-disk contract", () => {
  assert.equal(Model.BEGIN_MARK, "# >>> snooze >>>");
  assert.equal(Model.END_MARK, "# <<< snooze <<<");
  assert.equal(Model.MAX_DOMAINS, 500);
});

test("buildBlock writes one sinkhole line per domain between the marks", () => {
  assert.equal(Model.buildBlock(0, ["x.com"]),
    "# >>> snooze >>> until=0\n0.0.0.0 x.com\n# <<< snooze <<<");
  assert.equal(Model.buildBlock(7, []), "# >>> snooze >>> until=7\n# <<< snooze <<<");
});

test("hosts block round-trip preserves foreign content", () => {
  const base = "127.0.0.1 localhost\n::1 localhost\n";
  const withBlock = Model.applyBlock(base, 1755350400, ["x.com", "www.x.com"]);
  assert.ok(withBlock.includes("# >>> snooze >>> until=1755350400"));
  assert.ok(withBlock.includes("0.0.0.0 x.com"));
  const parsed = Model.parseHosts(withBlock);
  assert.equal(parsed.until, 1755350400);
  assert.deepEqual(parsed.domains, ["x.com", "www.x.com"]);
  assert.ok(parsed.rest.includes("127.0.0.1 localhost"));
  // re-apply must not grow blank lines
  const again = Model.applyBlock(withBlock, 99, ["y.com"]);
  assert.ok(!again.includes("\n\n\n"));
  assert.equal(Model.parseHosts(again).domains.length, 1);
});

test("parseHosts with no block", () => {
  const parsed = Model.parseHosts("127.0.0.1 localhost\n");
  assert.equal(parsed.until, null);
  assert.deepEqual(parsed.domains, []);
});

test("parseHosts keeps lines that follow the block and reads until=0", () => {
  const text = "127.0.0.1 localhost\n"
    + "# >>> snooze >>> until=0\n0.0.0.0 x.com\n# <<< snooze <<<\n"
    + "10.0.0.5 intranet\n";
  const parsed = Model.parseHosts(text);
  assert.equal(parsed.until, 0);
  assert.deepEqual(parsed.domains, ["x.com"]);
  assert.ok(parsed.rest.includes("10.0.0.5 intranet"));
  assert.ok(!parsed.rest.includes("0.0.0.0 x.com"));
  assert.ok(!parsed.rest.includes("snooze"));
});

test("unterminated block never swallows content below it", () => {
  const broken = "127.0.0.1 localhost\n# >>> snooze >>> until=5\n0.0.0.0 x.com\n10.0.0.5 intranet\n";
  const parsed = Model.parseHosts(broken);
  assert.equal(parsed.until, null);
  assert.ok(parsed.rest.includes("10.0.0.5 intranet"));
  assert.ok(parsed.rest.includes("# >>> snooze >>>"));
});

test("an unterminated block is repaired, not deleted, on the next write", () => {
  const broken = "127.0.0.1 localhost\n# >>> snooze >>> until=5\n0.0.0.0 x.com\n10.0.0.5 intranet\n";
  const fixed = Model.applyBlock(broken, 42, ["y.com"]);
  assert.ok(fixed.includes("10.0.0.5 intranet"));
  const reparsed = Model.parseHosts(fixed);
  assert.equal(reparsed.until, 42);
  assert.deepEqual(reparsed.domains, ["y.com"]);
});

test("a stray end marker above the block does not re-arm the swallow", () => {
  const broken = "# <<< snooze <<<\n127.0.0.1 localhost\n# >>> snooze >>> until=5\n10.0.0.5 intranet\n";
  const parsed = Model.parseHosts(broken);
  assert.equal(parsed.until, null);
  assert.ok(parsed.rest.includes("10.0.0.5 intranet"));
});

test("validateGroups", async () => {
  const fs = await import("node:fs");
  const defaults = JSON.parse(fs.readFileSync(new URL("../defaults/groups.json", import.meta.url)));
  assert.ok(Model.validateGroups(defaults));
  assert.ok(!Model.validateGroups({ version: 2, groups: [] }));
  assert.ok(!Model.validateGroups({ version: 1, groups: [{ id: "a" }] }));
});

test("validateGroups rejects malformed members and accepts a missing icon", () => {
  assert.ok(Model.validateGroups({ version: 1, groups: [] }));
  assert.ok(Model.validateGroups({ version: 1, groups: [{ id: "a", name: "A", sites: [] }] }));
  assert.ok(!Model.validateGroups(null));
  assert.ok(!Model.validateGroups({ version: 1 }));
  assert.ok(!Model.validateGroups({ version: 1, groups: [{ id: "", name: "A", sites: [] }] }));
  assert.ok(!Model.validateGroups({ version: 1, groups: [{ id: "a", name: "A", sites: "x.com" }] }));
  assert.ok(!Model.validateGroups({ version: 1, groups: [{ id: "a", name: "A", sites: [1] }] }));
  assert.ok(!Model.validateGroups({ version: 1, groups: [{ id: "a", name: "A", icon: 5, sites: [] }] }));
});
