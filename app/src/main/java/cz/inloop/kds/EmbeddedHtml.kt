package cz.inloop.kds

object EmbeddedHtml {
    const val UI_HTML = """
<!DOCTYPE html>
<html lang="cs">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>InLoop Trust KDS Standalone</title>
    <style>
        :root {
            --bg-base: #030712;
            --surface-glass: rgba(15, 23, 42, 0.75);
            --surface-card: rgba(30, 41, 59, 0.45);
            --surface-active: rgba(56, 189, 248, 0.15);
            --stroke-glass: rgba(255, 255, 255, 0.08);
            --accent-cyan: #38bdf8;
            --emerald: #10b981;
            --emerald-glow: rgba(16, 185, 129, 0.3);
            --rose: #f43f5e;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --text-dim: #64748b;
        }

        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; margin: 0; padding: 0; user-select: none; }
        body { background: var(--bg-base); color: var(--text-main); font-family: system-ui, sans-serif; min-height: 100vh; padding: 1rem; }

        .nav-bar { display: flex; justify-content: space-between; align-items: center; padding: 0.85rem 1.4rem; background: var(--surface-glass); border: 1px solid var(--stroke-glass); border-radius: 20px; margin-bottom: 1.2rem; }
        .brand { font-size: 1.2rem; font-weight: 800; color: #fff; }
        .brand span { color: var(--accent-cyan); }
        .capsule { background: rgba(16, 185, 129, 0.1); border: 1px solid var(--emerald); color: var(--emerald); padding: 0.35rem 0.8rem; border-radius: 12px; font-size: 0.75rem; font-weight: 700; }

        .workspace { display: grid; grid-template-columns: 1.3fr 1fr; gap: 1.2rem; }
        @media (max-width: 800px) { .workspace { grid-template-columns: 1fr; } }

        .glass-panel { background: var(--surface-glass); border: 1px solid var(--stroke-glass); border-radius: 22px; padding: 1.3rem; display: flex; flex-direction: column; }
        .section-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; font-size: 0.82rem; font-weight: 800; color: var(--text-dim); }

        .menu-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin-bottom: 1.2rem; }
        .dish-card { background: var(--surface-card); border: 1px solid var(--stroke-glass); border-radius: 16px; padding: 1rem; cursor: pointer; min-height: 90px; }
        .dish-card.active { background: var(--surface-active); border-color: var(--accent-cyan); box-shadow: 0 0 20px rgba(56, 189, 248, 0.2); }
        .dish-tag { font-size: 0.7rem; font-weight: 800; color: var(--accent-cyan); margin-bottom: 0.2rem; }
        .dish-name { font-size: 0.92rem; font-weight: 700; color: #fff; line-height: 1.3; }

        .metrics-row { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1.2rem; }
        .metric-tile { background: rgba(15, 23, 42, 0.4); border: 1px solid var(--stroke-glass); border-radius: 16px; padding: 1rem; }
        .metric-val-box { background: rgba(0,0,0,0.3); border-radius: 10px; padding: 0.7rem; text-align: center; margin: 0.5rem 0; font-size: 1.6rem; font-weight: 900; }
        
        .stepper { display: flex; gap: 0.3rem; }
        .btn-step { flex: 1; padding: 0.6rem 0.2rem; background: rgba(255,255,255,0.05); border: 1px solid var(--stroke-glass); color: #fff; font-weight: 800; border-radius: 8px; cursor: pointer; }
        .btn-step:active { background: var(--accent-cyan); color: #000; }

        .actions-cluster { display: grid; grid-template-columns: 1.3fr 1fr; gap: 0.8rem; margin-top: auto; }
        .btn-act { padding: 1.2rem; border-radius: 14px; border: none; font-size: 1rem; font-weight: 800; cursor: pointer; text-transform: uppercase; }
        .btn-dispatch { background: linear-gradient(135deg, #38bdf8, #2563eb); color: #000; }
        .btn-accept { background: rgba(255, 255, 255, 0.08); border: 1px solid var(--stroke-glass); color: #fff; }

        .stream-container { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 0.6rem; max-height: 520px; }
        .stream-card { background: rgba(15, 23, 42, 0.5); border: 1px solid var(--stroke-glass); border-radius: 14px; padding: 0.9rem; display: flex; justify-content: space-between; align-items: center; }
        .stream-title { font-size: 0.9rem; font-weight: 800; color: #fff; }
        .stream-meta { font-size: 0.75rem; color: var(--text-dim); margin-top: 0.2rem; }
        .badge-disp { background: rgba(16, 185, 129, 0.15); color: var(--emerald); border: 1px solid rgba(16, 185, 129, 0.3); padding: 0.35rem 0.65rem; border-radius: 6px; font-size: 0.72rem; font-weight: 800; }

        .modal { position: fixed; inset: 0; background: rgba(3, 7, 18, 0.85); display: flex; justify-content: center; align-items: center; z-index: 9999; opacity: 0; pointer-events: none; transition: opacity 0.2s; padding: 1.5rem; }
        .modal.active { opacity: 1; pointer-events: auto; }
        .modal-sheet { background: rgba(30, 41, 59, 0.95); border: 1px solid var(--stroke-glass); border-radius: 24px; padding: 2rem; max-width: 420px; width: 100%; text-align: center; }
        .modal-btn { width: 100%; padding: 1rem; border-radius: 12px; border: none; font-size: 1rem; font-weight: 800; cursor: pointer; margin-top: 1.5rem; }
    </style>
</head>
<body>

    <div class="nav-bar">
        <div class="brand"><span>INLOOP</span> TRUST KDS</div>
        <div class="capsule">STANDALONE EMBEDDED NODE</div>
    </div>

    <div class="workspace">
        <div class="glass-panel">
            <div class="section-header">
                <span>1. Položka denního menu</span>
                <span>Port 5005 (Vnitřní uzel)</span>
            </div>

            <div class="menu-grid">
                <div class="dish-card active" onclick="selectDish(this, 'MENU_1', 'Hovězí svíčková na smetaně, knedlík', 145.0)">
                    <div class="dish-tag">MENU 01 (145 Kč)</div>
                    <div class="dish-name">Hovězí svíčková na smetaně, knedlík</div>
                </div>
                <div class="dish-card" onclick="selectDish(this, 'MENU_2', 'Kuřecí steak s bylinkami', 139.0)">
                    <div class="dish-tag">MENU 02 (139 Kč)</div>
                    <div class="dish-name">Kuřecí steak, grilovaná zelenina</div>
                </div>
            </div>

            <div class="metrics-row">
                <div class="metric-tile">
                    <span style="font-size:0.75rem; color:var(--text-dim); font-weight:700;">POČET PORCÍ</span>
                    <div class="metric-val-box" id="disp-portions">45</div>
                    <div class="stepper">
                        <button class="btn-step" onclick="modPortions(-5)">-5</button>
                        <button class="btn-step" onclick="modPortions(-1)">-1</button>
                        <button class="btn-step" onclick="modPortions(1)">+1</button>
                        <button class="btn-step" onclick="modPortions(5)">+5</button>
                    </div>
                </div>

                <div class="metric-tile">
                    <span style="font-size:0.75rem; color:var(--text-dim); font-weight:700;">HACCP TEPLOTA</span>
                    <div class="metric-val-box" id="disp-temp">76.5 °C</div>
                    <div class="stepper">
                        <button class="btn-step" onclick="modTemp(-1.0)">-1°</button>
                        <button class="btn-step" onclick="modTemp(1.0)">+1°</button>
                    </div>
                </div>
            </div>

            <div class="actions-cluster">
                <button class="btn-act btn-dispatch" onclick="commitIntent('DISPATCH_BATCH')">EXPEDOVAT VÁRKU</button>
                <button class="btn-act btn-accept" onclick="commitIntent('ACCEPT_BATCH')">PŘIJMOUT</button>
            </div>
        </div>

        <div class="glass-panel">
            <div class="section-header">
                <span>Krystalický feed</span>
                <a href="/audit" target="_blank" style="color:var(--accent-cyan); text-decoration:none; font-weight:700;">Úřední audit ↗</a>
            </div>
            <div class="stream-container" id="stream-feed"></div>
        </div>
    </div>

    <!-- Modals -->
    <div id="modal-error" class="modal">
        <div class="modal-sheet">
            <h3 style="color:var(--rose);">HACCP Stop-Stav</h3>
            <p style="color:var(--text-muted); margin-top:0.5rem;" id="modal-err-msg">Naměřená teplota je pod normou 65.0 °C!</p>
            <button class="modal-btn" style="background:var(--rose); color:#fff;" onclick="closeModal('modal-error')">ROZUMÍM</button>
        </div>
    </div>

    <div id="modal-success" class="modal">
        <div class="modal-sheet">
            <h3 style="color:var(--emerald);">Zapečetěno v Krystalu</h3>
            <p style="color:var(--text-muted); margin-top:0.5rem;" id="modal-succ-msg">Várka byla autorizována a uložena.</p>
            <button class="modal-btn" style="background:var(--emerald); color:#000;" onclick="closeModal('modal-success')">HOTOVO</button>
        </div>
    </div>

    <script>
        let dishCode = "MENU_1";
        let dishName = "Hovězí svíčková na smetaně, knedlík";
        let unitPrice = 145.0;
        let portions = 45;
        let temperature = 76.5;

        function selectDish(el, code, name, price) {
            document.querySelectorAll('.dish-card').forEach(c => c.classList.remove('active'));
            el.classList.add('active');
            dishCode = code;
            dishName = name;
            unitPrice = price;
        }

        function modPortions(d) {
            portions = Math.max(1, Math.min(250, portions + d));
            document.getElementById('disp-portions').innerText = portions;
        }

        function modTemp(d) {
            temperature = Math.round((temperature + d) * 10) / 10;
            document.getElementById('disp-temp').innerText = temperature.toFixed(1) + " °C";
        }

        function showModal(id, msg) {
            if (msg) document.querySelector(`#${id} p`).innerText = msg;
            document.getElementById(id).classList.add('active');
        }

        function closeModal(id) {
            document.getElementById(id).classList.remove('active');
        }

        async function commitIntent(action) {
            const intent = {
                action: action,
                item: dishCode,
                item_name: dishName,
                unit_price: unitPrice,
                portions: portions,
                temperature: temperature,
                requested_at: Date.now() / 1000
            };

            const pf = await fetch('/api/macaroon/preflight', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ intent: intent })
            });
            const pfData = await pf.json();
            if (pfData.status !== "SUCCESS") {
                showModal('modal-error', pfData.message);
                return;
            }

            const cRes = await fetch('/api/auth/challenge');
            const { challenge } = await cRes.json();

            const res = await fetch('/api/crystallize', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    intent: intent,
                    fido_id: "standalone_hardware_node",
                    challenge: challenge,
                    signature: "STANDALONE_SIG_" + Date.now()
                })
            });

            const r = await res.json();
            if (r.ui_feedback === "SUCCESS") {
                showModal('modal-success', `Zapsáno: ${intent.item_name} (${intent.portions} ks).`);
                loadRecords();
            }
        }

        function loadRecords() {
            fetch('/api/records').then(r => r.json()).then(data => {
                const feed = document.getElementById('stream-feed');
                feed.innerHTML = '';
                data.records.reverse().forEach(r => {
                    const isDisp = r.intent.action === 'DISPATCH_BATCH';
                    const date = new Date(r.bitemporal.transaction_time * 1000).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
                    feed.innerHTML += `
                        <div class="stream-card">
                            <div>
                                <div class="stream-title">${r.intent.item_name}</div>
                                <div class="stream-meta">${r.intent.portions} ks × ${r.intent.unit_price} Kč • ${r.intent.temperature} °C • ${date}</div>
                            </div>
                            <div class="badge-disp">${isDisp ? 'EXPEDOVÁNO' : 'PŘIJATO'}</div>
                        </div>
                    `;
                });
            });
        }

        loadRecords();
        setInterval(loadRecords, 3000);
    </script>
</body>
</html>
    """.trimIndent()
}
