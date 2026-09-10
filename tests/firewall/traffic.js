"use strict";

const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const [mode, ...args] = process.argv.slice(2);

function connect(host, port) {
    return new Promise((resolve) => {
        const start = Date.now();
        const socket = net.connect({ host, port: Number(port) });
        let settled = false;
        const finish = (result) => {
            if (settled) return;
            settled = true;
            socket.destroy();
            resolve({ result, elapsed: Date.now() - start });
        };
        socket.setTimeout(700, () => finish("timeout"));
        socket.once("connect", () => finish("connected"));
        socket.once("error", (error) => finish(error.code));
    });
}

async function main() {
    if (mode === "topology") {
        const decode = (hex) => hex.match(/../g).reverse().map((byte) => parseInt(byte, 16)).join(".");
        const routes = fs.readFileSync("/proc/net/route", "utf8").trim().split("\n").slice(1);
        for (const route of routes) {
            const fields = route.trim().split(/\s+/);
            const destination = decode(fields[1]);
            const mask = parseInt(fields[7].match(/../g).reverse().join(""), 16);
            const controlled = destination.startsWith(`${args[0]}.`) && (mask >>> 8) === 0xffffff;
            const loopback = destination.startsWith("127.") && (mask >>> 24) === 0xff;
            if (fields[2] !== "00000000" || !(controlled || loopback)) {
                throw new Error(`namespace has a route outside controlled networking: ${route}`);
            }
        }
        for (const route of fs.readFileSync("/proc/net/ipv6_route", "utf8").trim().split("\n")) {
            const fields = route.trim().split(/\s+/);
            const flags = parseInt(fields[8], 16);
            if ((flags & 1) && !(flags & 0x200)
                && !(fields[0].startsWith("ff") && /^0{32}$/.test(fields[4]))
                && !/^fe[89ab]/i.test(fields[0]) && !/^0{31}1$/.test(fields[0])) {
                throw new Error(`namespace has a non-local IPv6 route: ${route}`);
            }
        }
        const addresses = fs.readFileSync("/proc/net/if_inet6", "utf8").trim();
        for (const line of addresses ? addresses.split("\n") : []) {
            const address = line.split(/\s+/)[0];
            if (!/^0{31}1$/.test(address) && !/^fe[89ab]/i.test(address)) {
                throw new Error(`namespace has a non-local IPv6 address: ${address}`);
            }
        }
    } else if (mode === "server") {
        const server = http.createServer((_request, response) => response.end("synthetic E1 peer\n"));
        server.on("error", (error) => { console.error(error); process.exit(1); });
        server.listen(Number(args[1]), args[0], () => fs.writeFileSync(args[2], "ready\n"));
    } else if (mode === "probe") {
        const result = await connect(args[0], args[1]);
        const expected = args[2] === "allow" ? "connected" : "ECONNREFUSED";
        if (result.result !== expected || result.elapsed >= 700) {
            throw new Error(`probe ${args[0]}:${args[1]} expected ${expected}, got ${JSON.stringify(result)}`);
        }
    } else if (mode === "watch") {
        const [forbidden, stop, report] = args;
        const stats = { attempts: 0, forbiddenSuccess: 0, forbiddenUnexpected: 0, loopbackFailures: 0 };
        const end = Date.now() + 90000;
        while (!fs.existsSync(stop) && Date.now() < end) {
            const results = await Promise.all([
                connect(forbidden, 443), connect("127.0.0.1", 8080),
            ]);
            stats.attempts++;
            if (results[0].result === "connected") stats.forbiddenSuccess++;
            else if (results[0].result !== "ECONNREFUSED") stats.forbiddenUnexpected++;
            if (results[1].result !== "connected") stats.loopbackFailures++;
            await new Promise((resolve) => setTimeout(resolve, 3));
        }
        fs.writeFileSync(report, JSON.stringify(stats));
        if (!fs.existsSync(stop)) throw new Error("traffic watch exceeded its deadline");
    } else if (mode === "report") {
        const stats = JSON.parse(fs.readFileSync(args[0], "utf8"));
        if (stats.attempts < 30 || stats.forbiddenSuccess || stats.forbiddenUnexpected || stats.loopbackFailures) {
            throw new Error(`traffic regression: ${JSON.stringify(stats)}`);
        }
        console.log(`traffic: ${stats.attempts} forbidden refusals, zero successes; loopback available`);
    } else {
        throw new Error(`unknown traffic mode: ${mode}`);
    }
}
main().catch((error) => { console.error(error.message); process.exitCode = 1; });
