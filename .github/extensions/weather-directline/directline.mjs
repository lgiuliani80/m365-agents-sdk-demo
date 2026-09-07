import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const directLineBaseUrl = "https://directline.botframework.com/v3/directline";

function azureCliExecutable() {
    return process.platform === "win32" ? "az.cmd" : "az";
}

function validateAzureResourceConfig(config) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(config.subscriptionId)) {
        throw new Error("The Azure subscription ID is invalid.");
    }
    if (!/^[\w().-]{1,90}$/.test(config.resourceGroup)) {
        throw new Error("The Azure resource group name is invalid.");
    }
    if (!/^[A-Za-z0-9-]{2,64}$/.test(config.botName)) {
        throw new Error("The Azure Bot Service name is invalid.");
    }
}

async function getDirectLineSecret(config) {
    validateAzureResourceConfig(config);
    const subscriptionId = encodeURIComponent(config.subscriptionId);
    const resourceGroup = encodeURIComponent(config.resourceGroup);
    const botName = encodeURIComponent(config.botName);
    const resourceUrl = [
        "https://management.azure.com/subscriptions",
        subscriptionId,
        "resourceGroups",
        resourceGroup,
        "providers/Microsoft.BotService/botServices",
        botName,
        "channels/DirectLineChannel/listChannelWithKeys",
    ].join("/");

    const { stdout } = await execFileAsync(
        azureCliExecutable(),
        [
            "rest",
            "--method",
            "post",
            "--url",
            `${resourceUrl}?api-version=2022-09-15`,
            "--subscription",
            config.subscriptionId,
            "--output",
            "json",
        ],
        {
            timeout: 30_000,
            windowsHide: true,
            maxBuffer: 1024 * 1024,
            shell: process.platform === "win32",
        },
    );

    const channel = JSON.parse(stdout);
    const sites = channel?.properties?.properties?.sites ?? channel?.properties?.sites;
    if (!Array.isArray(sites) || sites.length === 0) {
        throw new Error("Azure Bot Service returned no Direct Line sites.");
    }

    const siteName = config.siteName ?? "Default Site";
    const site = sites.find((candidate) => candidate.siteName === siteName) ?? sites[0];
    const secret = site.key ?? site.key1;

    if (typeof secret !== "string" || secret.length === 0) {
        throw new Error(`Direct Line site '${site.siteName ?? siteName}' has no readable key.`);
    }

    return secret;
}

async function directLineRequest(path, options) {
    const response = await fetch(`${directLineBaseUrl}${path}`, options);
    if (!response.ok) {
        const detail = await response.text();
        throw new Error(`Direct Line request failed (${response.status}): ${detail.slice(0, 500)}`);
    }

    return response.status === 204 ? {} : response.json();
}

export async function createDirectLineToken(config) {
    const secret = await getDirectLineSecret(config);
    const userId = `dl_${randomUUID()}`;

    const token = await directLineRequest("/tokens/generate", {
        method: "POST",
        headers: {
            Authorization: `Bearer ${secret}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify({ user: { id: userId } }),
    });
    return { ...token, userId };
}

function extractReplies(activities, userId) {
    return activities
        .filter((activity) =>
            activity.type === "message"
            && activity.from?.id !== userId
            && typeof activity.text === "string"
            && activity.text.length > 0)
        .map((activity) => activity.text);
}

export async function startDirectLineConversation(config) {
    const issuedToken = await createDirectLineToken(config);
    const userId = issuedToken.userId;
    const conversation = await directLineRequest("/conversations", {
        method: "POST",
        headers: { Authorization: `Bearer ${issuedToken.token}` },
    });

    const token = conversation.token ?? issuedToken.token;
    const conversationId = conversation.conversationId;
    if (!token || !conversationId) {
        throw new Error("Direct Line did not return a token and conversation ID.");
    }

    let watermark;
    let welcomeReplies = [];
    const initializationDeadline = Date.now() + 10_000;
    while (Date.now() < initializationDeadline) {
        const query = watermark ? `?watermark=${encodeURIComponent(watermark)}` : "";
        const activitySet = await directLineRequest(
            `/conversations/${encodeURIComponent(conversationId)}/activities${query}`,
            { headers: { Authorization: `Bearer ${token}` } },
        );
        watermark = activitySet.watermark ?? watermark;
        welcomeReplies = extractReplies(activitySet.activities ?? [], userId);
        if (welcomeReplies.length > 0) {
            break;
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
    }

    return {
        conversationId,
        token,
        userId,
        watermark,
        welcomeReplies,
    };
}

export async function sendDirectLineConversationMessage(state, text) {
    await directLineRequest(`/conversations/${encodeURIComponent(state.conversationId)}/activities`, {
        method: "POST",
        headers: {
            Authorization: `Bearer ${state.token}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            type: "message",
            from: { id: state.userId, name: "Copilot Canvas" },
            text,
        }),
    });

    const deadline = Date.now() + 45_000;
    while (Date.now() < deadline) {
        const query = state.watermark ? `?watermark=${encodeURIComponent(state.watermark)}` : "";
        const activitySet = await directLineRequest(
            `/conversations/${encodeURIComponent(state.conversationId)}/activities${query}`,
            { headers: { Authorization: `Bearer ${state.token}` } },
        );

        state.watermark = activitySet.watermark ?? state.watermark;
        const replies = extractReplies(activitySet.activities ?? [], state.userId);
        if (replies.length > 0) {
            return { conversationId: state.conversationId, replies };
        }

        await new Promise((resolve) => setTimeout(resolve, 1_500));
    }

    throw new Error("Timed out waiting for the agent response.");
}

export async function sendDirectLineMessage(config, text) {
    const state = await startDirectLineConversation(config);
    return sendDirectLineConversationMessage(state, text);
}
