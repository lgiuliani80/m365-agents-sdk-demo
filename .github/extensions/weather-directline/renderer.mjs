function escapeHtml(value) {
    return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");
}

export function renderHtml(botName, initialMessage) {
    const safeBotName = escapeHtml(botName);
    const serializedInitialMessage = JSON.stringify(initialMessage ?? "").replaceAll("<", "\\u003c");

    return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Weather agent [Direct Line test]</title>
  <style>
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body {
      display: grid;
      grid-template-rows: auto 1fr auto;
      height: 100vh;
      margin: 0;
      background: var(--background-color-default, #ffffff);
      color: var(--text-color-default, #1f2328);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif);
      font-size: 14px;
    }
    header {
      align-items: center;
      border-bottom: 1px solid var(--border-color-default, #d0d7de);
      display: flex;
      gap: 12px;
      min-height: 64px;
      padding: 12px 16px;
    }
    .mark {
      align-items: center;
      background: #ddf4ff;
      border-radius: 10px;
      display: flex;
      font-size: 22px;
      height: 38px;
      justify-content: center;
      width: 38px;
    }
    h1 { font-size: 18px; margin: 0; }
    .subtitle, #status { color: var(--text-color-muted, #656d76); }
    #status { margin-left: auto; }
    #messages {
      display: flex;
      flex-direction: column;
      gap: 12px;
      overflow-y: auto;
      padding: 16px;
    }
    .message {
      border-radius: 12px;
      line-height: 1.5;
      max-width: 85%;
      padding: 10px 12px;
      white-space: pre-wrap;
    }
    .user { align-self: flex-end; background: #0969da; color: #fff; }
    .bot { align-self: flex-start; background: var(--background-color-muted, #f6f8fa); }
    .error { align-self: stretch; background: #ffebe9; border: 1px solid #cf222e; }
    form {
      border-top: 1px solid var(--border-color-default, #d0d7de);
      display: flex;
      gap: 8px;
      padding: 12px;
    }
    input {
      background: var(--background-color-default, #fff);
      border: 1px solid var(--border-color-default, #d0d7de);
      border-radius: 8px;
      color: inherit;
      flex: 1;
      font: inherit;
      padding: 10px 12px;
    }
    button {
      background: #1f883d;
      border: 0;
      border-radius: 8px;
      color: #fff;
      cursor: pointer;
      font-weight: 600;
      padding: 10px 16px;
    }
    #reset {
      background: transparent;
      border: 1px solid var(--border-color-default, #d0d7de);
      color: inherit;
    }
    button:disabled { cursor: wait; opacity: .6; }
  </style>
</head>
<body>
  <header>
    <div class="mark" aria-hidden="true">☁</div>
    <div>
      <h1>Weather agent [Direct Line test]</h1>
      <div class="subtitle">${safeBotName}</div>
    </div>
    <div id="status" role="status">Ready</div>
    <button id="reset" type="button">Reset</button>
  </header>
  <main id="messages" aria-live="polite"></main>
  <form id="composer">
    <input id="message" aria-label="Message" autocomplete="off" placeholder="Ask about the weather..." />
    <button id="send" type="submit">Send</button>
  </form>
  <script>
    (() => {
      const initialMessage = ${serializedInitialMessage};
      const form = document.getElementById("composer");
      const input = document.getElementById("message");
      const messages = document.getElementById("messages");
      const resetButton = document.getElementById("reset");
      const sendButton = document.getElementById("send");
      const status = document.getElementById("status");

      function appendMessage(text, className) {
        const element = document.createElement("div");
        element.className = "message " + className;
        element.textContent = text;
        messages.appendChild(element);
        messages.scrollTop = messages.scrollHeight;
      }

      async function sendMessage(text) {
        appendMessage(text, "user");
        input.disabled = true;
        resetButton.disabled = true;
        sendButton.disabled = true;
        status.textContent = "Thinking...";
        try {
          const response = await fetch("./api/message", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ text })
          });
          const payload = await response.json();
          if (!response.ok) {
            throw new Error(payload.error || "Unable to send the message.");
          }
          for (const reply of payload.replies || []) {
            appendMessage(reply, "bot");
          }
          status.textContent = "Ready";
        } catch (error) {
          appendMessage(error instanceof Error ? error.message : "Unexpected chat error.", "error");
          status.textContent = "Failed";
        } finally {
          input.disabled = false;
          resetButton.disabled = false;
          sendButton.disabled = false;
          input.focus();
        }
      }

      form.addEventListener("submit", event => {
        event.preventDefault();
        const text = input.value.trim();
        if (!text) return;
        input.value = "";
        sendMessage(text);
      });

      resetButton.addEventListener("click", async () => {
        input.disabled = true;
        resetButton.disabled = true;
        sendButton.disabled = true;
        status.textContent = "Resetting...";
        try {
          const response = await fetch("./api/reset", { method: "POST" });
          const payload = await response.json();
          if (!response.ok) {
            throw new Error(payload.error || "Unable to reset the conversation.");
          }
          messages.replaceChildren();
          for (const reply of payload.replies || []) {
            appendMessage(reply, "bot");
          }
          status.textContent = "Ready";
        } catch (error) {
          appendMessage(error instanceof Error ? error.message : "Unexpected reset error.", "error");
          status.textContent = "Failed";
        } finally {
          input.disabled = false;
          resetButton.disabled = false;
          sendButton.disabled = false;
          input.focus();
        }
      });

      if (initialMessage) {
        sendMessage(initialMessage);
      } else {
        input.focus();
      }
    })();
  </script>
</body>
</html>`;
}
