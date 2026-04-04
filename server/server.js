const WebSocket = require("ws");
const crypto = require("crypto");

const PORT = 7860;
const wss = new WebSocket.Server({ port: PORT });

const lobbies = new Map();
const playerSockets = new Map();

const TEAM_COLORS = [
    { r: 0.86, g: 0.20, b: 0.20 },
    { r: 0.20, g: 0.39, b: 0.86 },
    { r: 0.20, g: 0.78, b: 0.31 },
    { r: 0.86, g: 0.78, b: 0.20 },
    { r: 0.70, g: 0.20, b: 0.86 },
    { r: 0.86, g: 0.51, b: 0.20 },
    { r: 0.20, g: 0.78, b: 0.82 },
    { r: 0.86, g: 0.20, b: 0.59 },
];

const TEAM_NAMES = ["Red", "Blue", "Green", "Yellow", "Purple", "Orange", "Cyan", "Pink"];

const CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function generateCode() {
    let code;
    do {
        code = "";
        for (let i = 0; i < 6; i++) {
            code += CODE_CHARS[Math.floor(Math.random() * CODE_CHARS.length)];
        }
    } while (lobbies.has(code));
    return code;
}

function generateBoard(gridSize) {
    const cells = [];
    const used = new Set();
    for (let i = 0; i < gridSize * gridSize; i++) {
        let seed;
        do {
            seed = Math.floor(Math.random() * 4294967294) + 1;
        } while (used.has(seed));
        used.add(seed);
        cells.push({ seed, owner_team: null, best_time: null, best_player: null });
    }
    return cells;
}

function buildTeams(count) {
    const teams = [];
    for (let i = 0; i < count; i++) {
        teams.push({
            index: i,
            name: TEAM_NAMES[i] || `Team ${i + 1}`,
            color: TEAM_COLORS[i] || { r: 0.5, g: 0.5, b: 0.5 },
        });
    }
    return teams;
}

function redistributePlayers(players, teamCount) {
    const shuffled = [...players].sort(() => Math.random() - 0.5);
    shuffled.forEach((p, i) => { p.team = i % teamCount; });
}

function autoAssignTeam(players, teamCount) {
    const counts = new Array(teamCount).fill(0);
    for (const p of players) {
        if (p.team >= 0 && p.team < teamCount) counts[p.team]++;
    }
    return counts.indexOf(Math.min(...counts));
}

function checkBingo(cells, gridSize, team) {
    const owned = cells.map(c => c.owner_team === team);

    for (let r = 0; r < gridSize; r++) {
        const line = [];
        let win = true;
        for (let c = 0; c < gridSize; c++) {
            const idx = r * gridSize + c;
            line.push(idx);
            if (!owned[idx]) { win = false; break; }
        }
        if (win) return line;
    }

    for (let c = 0; c < gridSize; c++) {
        const line = [];
        let win = true;
        for (let r = 0; r < gridSize; r++) {
            const idx = r * gridSize + c;
            line.push(idx);
            if (!owned[idx]) { win = false; break; }
        }
        if (win) return line;
    }

    const d1 = [], d2 = [];
    let w1 = true, w2 = true;
    for (let i = 0; i < gridSize; i++) {
        const i1 = i * gridSize + i;
        const i2 = i * gridSize + (gridSize - 1 - i);
        d1.push(i1); d2.push(i2);
        if (!owned[i1]) w1 = false;
        if (!owned[i2]) w2 = false;
    }
    if (w1) return d1;
    if (w2) return d2;

    return null;
}

function lobbyPublicState(lobby) {
    return {
        code: lobby.code,
        host_id: lobby.host_id,
        settings: lobby.settings,
        players: lobby.players.map(p => ({ id: p.id, name: p.name, team: p.team })),
        teams: lobby.teams,
        state: lobby.state,
        board: lobby.board,
        winner_team: lobby.winner_team,
        winning_line: lobby.winning_line,
    };
}

function broadcast(lobby, msg) {
    const data = JSON.stringify(msg);
    for (const p of lobby.players) {
        if (p.ws && p.ws.readyState === WebSocket.OPEN) {
            p.ws.send(data);
        }
    }
}

function sendTo(ws, msg) {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

const HOST_TIMEOUT_MS = 10 * 60 * 1000;

function removePlayer(ws) {
    const entry = playerSockets.get(ws);
    if (!entry) return;
    playerSockets.delete(ws);

    const lobby = lobbies.get(entry.lobbyCode);
    if (!lobby) {
        console.log(`[removePlayer] lobby ${entry.lobbyCode} not found for player ${entry.playerId}`);
        return;
    }

    console.log(`[removePlayer] player ${entry.playerId} disconnected from lobby ${lobby.code} (state=${lobby.state})`);

    if (lobby.state === "in_game" || lobby.state === "finished") {
        const player = lobby.players.find(p => p.id === entry.playerId);
        if (player) player.ws = null;

        if (lobby.host_id === entry.playerId) {
            if (lobby.hostTimeoutHandle) clearTimeout(lobby.hostTimeoutHandle);
            console.log(`[removePlayer] host disconnected, starting 10m close timer for lobby ${lobby.code}`);
            lobby.hostTimeoutHandle = setTimeout(() => {
                console.log(`[hostTimeout] closing lobby ${lobby.code}`);
                broadcast(lobby, { type: "error", message: "Host disconnected. Lobby closed." });
                lobbies.delete(lobby.code);
            }, HOST_TIMEOUT_MS);
        }
        return;
    }

    lobby.players = lobby.players.filter(p => p.id !== entry.playerId);
    console.log(`[removePlayer] removed from waiting lobby, ${lobby.players.length} players remain`);

    if (lobby.players.length === 0) {
        console.log(`[removePlayer] lobby ${lobby.code} empty, deleting`);
        lobbies.delete(lobby.code);
        return;
    }

    if (lobby.host_id === entry.playerId) {
        if (lobby.hostTimeoutHandle) clearTimeout(lobby.hostTimeoutHandle);
        console.log(`[removePlayer] host left waiting lobby, starting 10m close timer for ${lobby.code}`);
        lobby.hostTimeoutHandle = setTimeout(() => {
            console.log(`[hostTimeout] closing lobby ${lobby.code}`);
            broadcast(lobby, { type: "error", message: "Host disconnected. Lobby closed." });
            lobbies.delete(lobby.code);
        }, HOST_TIMEOUT_MS);
    }

    broadcast(lobby, { type: "lobby_state", lobby: lobbyPublicState(lobby) });
}

function handleMessage(ws, msg) {
    if (typeof msg.type !== "string") return;

    switch (msg.type) {
        case "create_lobby": {
            const name = String(msg.player_name || "Player").slice(0, 32);
            const playerId = String(msg.player_id || crypto.randomBytes(8).toString("hex")).slice(0, 64);
            const code = generateCode();
            const lobby = {
                code,
                host_id: playerId,
                settings: { teams: 2, grid_size: 5 },
                players: [{ id: playerId, name, team: 0, ws }],
                teams: buildTeams(2),
                state: "waiting",
                board: null,
                winner_team: null,
                winning_line: null,
            };
            lobbies.set(code, lobby);
            playerSockets.set(ws, { lobbyCode: code, playerId });
            sendTo(ws, { type: "joined", player_id: playerId, lobby: lobbyPublicState(lobby) });
            break;
        }

        case "join_lobby": {
            const code = String(msg.code || "").toUpperCase().slice(0, 16);
            const lobby = lobbies.get(code);
            console.log(`[join_lobby] code=${code} found=${!!lobby} lobbies=[${[...lobbies.keys()].join(",")}]`);
            if (!lobby) { sendTo(ws, { type: "error", message: "Lobby not found" }); return; }

            const name = String(msg.player_name || "Player").slice(0, 32);
            const playerId = String(msg.player_id || crypto.randomBytes(8).toString("hex")).slice(0, 64);

            const existing = lobby.players.find(p => p.id === playerId);
            if (existing) {
                existing.ws = ws;
                playerSockets.set(ws, { lobbyCode: code, playerId });
                if (playerId === lobby.host_id && lobby.hostTimeoutHandle) {
                    clearTimeout(lobby.hostTimeoutHandle);
                    lobby.hostTimeoutHandle = null;
                }
                sendTo(ws, { type: "joined", player_id: playerId, lobby: lobbyPublicState(lobby) });
                return;
            }

            if (lobby.state !== "waiting") {
                sendTo(ws, { type: "error", message: "Game already in progress" });
                return;
            }

            const team = autoAssignTeam(lobby.players, lobby.settings.teams);
            lobby.players.push({ id: playerId, name, team, ws });
            playerSockets.set(ws, { lobbyCode: code, playerId });

            sendTo(ws, { type: "joined", player_id: playerId, lobby: lobbyPublicState(lobby) });
            broadcast(lobby, { type: "lobby_state", lobby: lobbyPublicState(lobby) });
            break;
        }

        case "update_settings": {
            const entry = playerSockets.get(ws);
            if (!entry) return;
            const lobby = lobbies.get(entry.lobbyCode);
            if (!lobby || lobby.host_id !== entry.playerId || lobby.state !== "waiting") return;

            const oldTeamCount = lobby.settings.teams;

            if (typeof msg.teams === "number") {
                lobby.settings.teams = Math.max(2, Math.min(8, Math.floor(msg.teams)));
            }
            if (typeof msg.grid_size === "number") {
                lobby.settings.grid_size = Math.max(3, Math.min(7, Math.floor(msg.grid_size)));
            }

            lobby.teams = buildTeams(lobby.settings.teams);

            if (lobby.settings.teams !== oldTeamCount) {
                redistributePlayers(lobby.players, lobby.settings.teams);
            }

            broadcast(lobby, { type: "lobby_state", lobby: lobbyPublicState(lobby) });
            break;
        }

        case "move_player": {
            const entry = playerSockets.get(ws);
            if (!entry) return;
            const lobby = lobbies.get(entry.lobbyCode);
            if (!lobby || lobby.state !== "waiting") return;

            const targetId = String(msg.player_id || "");
            const newTeam = Math.floor(Number(msg.team));

            if (entry.playerId !== lobby.host_id && entry.playerId !== targetId) return;
            if (newTeam < 0 || newTeam >= lobby.settings.teams) return;

            const player = lobby.players.find(p => p.id === targetId);
            if (!player) return;
            player.team = newTeam;

            broadcast(lobby, { type: "lobby_state", lobby: lobbyPublicState(lobby) });
            break;
        }

        case "start_game": {
            const entry = playerSockets.get(ws);
            if (!entry) return;
            const lobby = lobbies.get(entry.lobbyCode);
            if (!lobby || lobby.host_id !== entry.playerId || lobby.state !== "waiting") return;

            lobby.state = "in_game";
            lobby.board = generateBoard(lobby.settings.grid_size);
            lobby.winner_team = null;
            lobby.winning_line = null;

            broadcast(lobby, { type: "game_started", lobby: lobbyPublicState(lobby) });
            break;
        }

        case "submit_time": {
            const entry = playerSockets.get(ws);
            if (!entry) return;
            const lobby = lobbies.get(entry.lobbyCode);
            if (!lobby || lobby.state !== "in_game") return;

            const player = lobby.players.find(p => p.id === entry.playerId);
            if (!player) return;

            const cellIndex = Math.floor(Number(msg.cell_index));
            const timeMs = Math.floor(Number(msg.time_ms));

            if (!Number.isFinite(cellIndex) || cellIndex < 0 || cellIndex >= lobby.board.length) return;
            if (!Number.isFinite(timeMs) || timeMs <= 0) return;

            const cell = lobby.board[cellIndex];
            if (cell.best_time === null || timeMs < cell.best_time) {
                cell.best_time = timeMs;
                cell.owner_team = player.team;
                cell.best_player = player.name;

                broadcast(lobby, {
                    type: "cell_updated",
                    cell_index: cellIndex,
                    cell: { seed: cell.seed, owner_team: cell.owner_team, best_time: cell.best_time, best_player: cell.best_player },
                });

                if (lobby.winner_team === null) {
                    const line = checkBingo(lobby.board, lobby.settings.grid_size, player.team);
                    if (line) {
                        lobby.winner_team = player.team;
                        lobby.winning_line = line;
                        lobby.state = "finished";
                        broadcast(lobby, {
                            type: "bingo_win",
                            team: player.team,
                            team_name: lobby.teams[player.team].name,
                            winning_line: line,
                            lobby: lobbyPublicState(lobby),
                        });
                    }
                }
            }
            break;
        }

        case "request_state": {
            const entry = playerSockets.get(ws);
            if (!entry) return;
            const lobby = lobbies.get(entry.lobbyCode);
            if (!lobby) return;
            sendTo(ws, { type: "lobby_state", lobby: lobbyPublicState(lobby) });
            break;
        }

        case "leave_lobby": {
            removePlayer(ws);
            break;
        }

        default:
            sendTo(ws, { type: "error", message: "Unknown message type: " + msg.type });
    }
}

const PING_INTERVAL_MS = 30_000;
const PING_TIMEOUT_MS = 10_000;

wss.on("connection", (ws) => {
    ws.isAlive = true;

    ws.on("pong", () => { ws.isAlive = true; });

    ws.on("message", (raw) => {
        let msg;
        try { msg = JSON.parse(raw); } catch { sendTo(ws, { type: "error", message: "Invalid JSON" }); return; }
        handleMessage(ws, msg);
    });

    ws.on("close", () => removePlayer(ws));
    ws.on("error", () => removePlayer(ws));
});

const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
        if (!ws.isAlive) {
            ws.terminate();
            continue;
        }
        ws.isAlive = false;
        ws.ping();
    }
}, PING_INTERVAL_MS);

wss.on("close", () => clearInterval(heartbeat));

wss.on("listening", () => {
    console.log(`Noita Bingo server listening on ws://localhost:${PORT}`);
});
