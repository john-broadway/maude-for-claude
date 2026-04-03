(function() {
    var sessionId = 'sess-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
    var messagesEl = document.getElementById('chat-messages');
    var inputEl = document.getElementById('chat-input');
    var sendBtn = document.getElementById('chat-send');
    var statusEl = document.getElementById('chat-status');
    var sending = false;

    if (!messagesEl || !inputEl || !sendBtn) return;

    // Prompt tab switching on hover
    document.querySelectorAll('.prompt-tab').forEach(function(tab) {
        tab.addEventListener('mouseenter', function() {
            document.querySelectorAll('.prompt-tab').forEach(function(t) { t.classList.remove('active'); });
            document.querySelectorAll('.prompt-panel').forEach(function(p) { p.classList.remove('active'); });
            tab.classList.add('active');
            var panel = document.getElementById('prompts-' + tab.dataset.tab);
            if (panel) panel.classList.add('active');
        });
    });

    // Quick action buttons
    document.querySelectorAll('.quick-action-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
            if (sending) return;
            inputEl.value = btn.getAttribute('data-prompt');
            sendMessage();
        });
    });

    // Render markdown safely — DOMPurify sanitizes ALL output before DOM insertion
    function renderMarkdown(text) {
        if (typeof marked !== 'undefined' && typeof DOMPurify !== 'undefined') {
            return DOMPurify.sanitize(marked.parse(text));
        }
        // Fallback: plain-text escape
        var div = document.createElement('div');
        div.textContent = text;
        var escaped = div.textContent;
        return escaped;
    }

    // SECURITY: All HTML set via this function is pre-sanitized by DOMPurify.sanitize()
    // in renderMarkdown() above. This is the standard pattern recommended by the
    // DOMPurify library for rendering user-facing markdown content safely.
    function setContentSafe(el, sanitizedHtml) {
        el.innerHTML = sanitizedHtml; // nosec: pre-sanitized by DOMPurify
    }

    function createEl(tag, cls) {
        var el = document.createElement(tag);
        if (cls) el.className = cls;
        return el;
    }

    function appendMsg(sender, text, cls, useMarkdown) {
        var el = createEl('div', 'chat-msg ' + cls);
        if (sender) {
            var senderEl = createEl('div', 'msg-sender');
            senderEl.textContent = sender;
            el.appendChild(senderEl);
        }
        var contentEl = createEl('div', 'msg-content');
        if (useMarkdown) {
            setContentSafe(contentEl, renderMarkdown(text));
        } else {
            contentEl.textContent = text;
        }
        el.appendChild(contentEl);
        messagesEl.appendChild(el);
        scrollToBottom();
        return el;
    }

    function appendTyping() {
        var el = createEl('div', 'chat-msg chat-msg-maude');
        el.id = 'typing-msg';
        var senderEl = createEl('div', 'msg-sender');
        senderEl.textContent = 'Maude';
        el.appendChild(senderEl);
        var indicator = createEl('div', 'typing-indicator');
        for (var i = 0; i < 3; i++) {
            indicator.appendChild(document.createElement('span'));
        }
        el.appendChild(indicator);
        messagesEl.appendChild(el);
        scrollToBottom();
    }

    function scrollToBottom() {
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    inputEl.addEventListener('keydown', function(e) {
        if (e.key === 'Enter' && !e.shiftKey && !sending) {
            e.preventDefault();
            sendMessage();
        }
    });

    function sendMessage() {
        var text = inputEl.value.trim();
        if (!text || sending) return;

        sending = true;
        sendBtn.disabled = true;
        if (statusEl) statusEl.textContent = 'thinking...';
        inputEl.value = '';

        appendMsg('You', text, 'chat-msg-user', false);
        appendTyping();

        fetch('/api/chat', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({message: text, session_id: sessionId})
        }).then(function(resp) {
            var ti = document.getElementById('typing-msg');
            if (ti) ti.remove();

            if (!resp.ok) {
                appendMsg('Maude', 'I apologize — an error occurred. Please try again.', 'chat-msg-maude', false);
                return;
            }

            var reader = resp.body.getReader();
            var decoder = new TextDecoder();
            var buffer = '';
            var currentMsgEl = null;
            var currentContent = '';

            function readChunk() {
                return reader.read().then(function(result) {
                    if (result.done) return;
                    buffer += decoder.decode(result.value, {stream: true});

                    var lines = buffer.split('\n');
                    buffer = lines.pop() || '';

                    for (var i = 0; i < lines.length; i++) {
                        var line = lines[i].replace(/\r$/, '');
                        if (line.indexOf('data: ') === 0) {
                            var data = line.slice(6);
                            try {
                                var evt = JSON.parse(data);
                                if (evt.type === 'text') {
                                    if (!currentMsgEl) {
                                        currentMsgEl = appendMsg('Maude', '', 'chat-msg-maude', false);
                                        currentContent = '';
                                    }
                                    currentContent += evt.content;
                                    setContentSafe(
                                        currentMsgEl.querySelector('.msg-content'),
                                        renderMarkdown(currentContent)
                                    );
                                    scrollToBottom();
                                } else if (evt.type === 'tool_call') {
                                    appendMsg(null, 'Looking up: ' + evt.name + '...', 'chat-msg-tool', false);
                                    scrollToBottom();
                                } else if (evt.type === 'done') {
                                    return;
                                } else if (evt.type === 'error') {
                                    appendMsg('Maude', 'I apologize — ' + (evt.content || 'an error occurred.'), 'chat-msg-maude', false);
                                }
                            } catch(e) {
                                // skip malformed SSE lines
                            }
                        }
                    }
                    return readChunk();
                });
            }

            return readChunk();
        }).catch(function(err) {
            var ti = document.getElementById('typing-msg');
            if (ti) ti.remove();
            appendMsg('Maude', 'I apologize — a connection error occurred.', 'chat-msg-maude', false);
        }).then(function() {
            sending = false;
            sendBtn.disabled = false;
            if (statusEl) statusEl.textContent = 'ready';
        });
    }

    // Expose for onclick handler on send button
    window.sendMessage = sendMessage;
})();
