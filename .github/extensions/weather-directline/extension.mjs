import { createServer } from "node:http";
import { randomBytes } from "node:crypto";
import { createCanvas, joinSession } from "@github/copilot-sdk/extension";
import {
    createDirectLineToken,
    sendDirectLineConversationMessage,
    sendDirectLineMessage,
    startDirectLineConversation,
} from "./directline.mjs";
import { renderHtml } from "./renderer.mjs";

const servers = new Map();

function writeJson(response, statusCode, value) {
    response.writeHead(statusCode, {
        "Cache-Control": "no-store",
        "Content-Type": "application/json; charset=utf-8",
    });
    response.end(JSON.stringify(value));
}

async function readJson(request) {
    const chunks = [];
    let size = 0;

    for await (const chunk of request) {
        size += chunk.length;
        if (size > 16 * 1024) {
            throw new Error("Request body is too large.");
        }
        chunks.push(chunk);
    }

    return chunks.length === 0
        ? {}
        : JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function startServer(instanceId, input) {
    const nonce = randomBytes(24).toString("hex");
    let origin;
    let conversationPromise;

    const server = createServer(async (request, response) => {
        try {
            const requestUrl = new URL(request.url ?? "/", origin);
            const expectedPrefix = `/${nonce}`;

            if (!requestUrl.pathname.startsWith(expectedPrefix)) {
                response.writeHead(404);
                response.end();
                return;
            }

            if (requestUrl.pathname === `${expectedPrefix}/`) {
                response.writeHead(200, {
                    "Cache-Control": "no-store",
                    "Content-Security-Policy": [
                        "default-src 'none'",
                        "script-src 'unsafe-inline'",
                        "style-src 'unsafe-inline'",
                        "img-src data: https:",
                        "connect-src 'self'",
                        "font-src data:",
                    ].join("; "),
                    "Content-Type": "text/html; charset=utf-8",
                    "Referrer-Policy": "no-referrer",
                    "X-Content-Type-Options": "nosniff",
                });
                response.end(renderHtml(input.botName, input.initialMessage));
                return;
            }

            if (request.method !== "POST" || request.headers.origin !== origin) {
                writeJson(response, 403, { error: "Request origin or method is not allowed." });
                return;
            }

            if (requestUrl.pathname === `${expectedPrefix}/api/token`) {
                const token = await createDirectLineToken(input);
                writeJson(response, 200, token);
                return;
            }

            if (requestUrl.pathname === `${expectedPrefix}/api/message`) {
                const body = await readJson(request);
                if (typeof body.text !== "string" || body.text.trim().length === 0) {
                    writeJson(response, 400, { error: "A non-empty message is required." });
                    return;
                }

                conversationPromise ??= startDirectLineConversation(input).catch((error) => {
                    conversationPromise = undefined;
                    throw error;
                });
                const conversation = await conversationPromise;
                const result = await sendDirectLineConversationMessage(conversation, body.text.trim());
                writeJson(response, 200, result);
                return;
            }

            if (requestUrl.pathname === `${expectedPrefix}/api/reset`) {
                conversationPromise = startDirectLineConversation(input).catch((error) => {
                    conversationPromise = undefined;
                    throw error;
                });
                const conversation = await conversationPromise;
                writeJson(response, 200, { replies: conversation.welcomeReplies });
                return;
            }

            response.writeHead(404);
            response.end();
        }
        catch (error) {
            writeJson(response, 500, {
                error: error instanceof Error ? error.message : "Unexpected Direct Line error.",
            });
        }
    });

    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : 0;
    origin = `http://127.0.0.1:${port}`;

    return {
        server,
        url: `${origin}/${nonce}/`,
        input,
        instanceId,
    };
}

const canvas = createCanvas({
    id: "weather-directline",
    displayName: "Weather agent [Direct Line test]",
    description: "Chat with the deployed weather agent through a securely brokered Direct Line token.",
    inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["subscriptionId", "resourceGroup", "botName"],
        properties: {
            subscriptionId: { type: "string", minLength: 36, maxLength: 36 },
            resourceGroup: { type: "string", minLength: 1 },
            botName: { type: "string", minLength: 2 },
            siteName: { type: "string", default: "Default Site" },
            initialMessage: { type: "string", minLength: 1, maxLength: 2000 },
        },
    },
    actions: [
        {
            name: "check_connection",
            description: "Verify that a short-lived Direct Line token can be issued.",
            handler: async (ctx) => {
                const entry = servers.get(ctx.instanceId);
                if (!entry) {
                    throw new Error("Open the canvas before checking its connection.");
                }

                const token = await createDirectLineToken(entry.input);
                return {
                    connected: true,
                    expiresIn: token.expires_in,
                    conversationId: token.conversationId,
                };
            },
        },
        {
            name: "send_message",
            description: "Send a smoke-test message to the weather agent and return its replies.",
            inputSchema: {
                type: "object",
                additionalProperties: false,
                required: ["text"],
                properties: {
                    text: { type: "string", minLength: 1, maxLength: 2000 },
                },
            },
            handler: async (ctx) => {
                const entry = servers.get(ctx.instanceId);
                if (!entry) {
                    throw new Error("Open the canvas before sending a message.");
                }

                return sendDirectLineMessage(entry.input, ctx.input.text);
            },
        },
    ],
    open: async (ctx) => {
        let entry = servers.get(ctx.instanceId);
        if (!entry) {
            entry = await startServer(ctx.instanceId, ctx.input);
            servers.set(ctx.instanceId, entry);
        }

        return {
            title: "Weather agent [Direct Line test]",
            status: "Direct Line",
            url: entry.url,
        };
    },
    onClose: async (ctx) => {
        const entry = servers.get(ctx.instanceId);
        if (entry) {
            servers.delete(ctx.instanceId);
            await new Promise((resolve) => entry.server.close(resolve));
        }
    },
});

await joinSession({ canvases: [canvas] });
