// KeyPhone runner: runs one Java ME app inside the phone's screen.
// The phone (parent page) talks to this page with postMessage:
//   phone → here: {t:'run', id, name, jar:ArrayBuffer} · {t:'key', code, down}
//   here → phone: {t:'ready'} · {t:'status', text} · {t:'started'} · {t:'exit'} · {t:'error', text}
import { LibMedia } from "../libmedia/libmedia.js";
import { LibMidi, createUnlockingAudioContext } from "../libmidi/libmidi.js";
import { codeMap, KeyRepeatManager } from "./key.js";
import { EventQueue } from "./eventqueue.js";
import canvasFontNatives from "../libjs/libcanvasfont.js";
import canvasGraphicsNatives from "../libjs/libcanvasgraphics.js";
import gles2Natives from "../libjs/libgles2.js";
import jsReferenceNatives from "../libjs/libjsreference.js";
import mediaBridgeNatives from "../libjs/libmediabridge.js";
import midiBridgeNatives from "../libjs/libmidibridge.js";

const evtQueue = new EventQueue();
window.evtQueue = evtQueue;
const webRoot = '/app' + location.pathname.replace(/\/[^/]*$/, '');
const display = document.getElementById('display');
const screenCtx = display.getContext('2d');
const msgBox = document.getElementById('msg');
const msgText = document.getElementById('msgt');
const keys = new KeyRepeatManager();

let lib = null;
let pending = null;
let started = false;

function tell(m) { try { parent.postMessage(m, '*'); } catch (e) {} }
function status(text) { msgText.textContent = text; tell({ t: 'status', text }); }

function fit() {
    if (!display.width) return;
    const s = Math.min(innerWidth / display.width, innerHeight / display.height);
    display.style.width = (display.width * s) + 'px';
    display.style.height = (display.height * s) + 'px';
}
addEventListener('resize', fit);

// ---- input: keys from the phone, the keyboard, and touches on the screen
keys.register((kind, key, args) => {
    if (kind === 'click' || !codeMap[key]) return;
    evtQueue.queueEvent({
        kind: kind === 'up' ? 'keyup' : 'keydown',
        args: [codeMap[key], args.symbol, false, false]
    });
});
function postKey(down, code) {
    if (!codeMap[code]) return;
    const symbol = code.startsWith('Digit') ? code.substring(5) : '\x00';
    keys.post(down, code, { symbol, ctrlKey: false, shiftKey: false });
}
function onKey(e) {
    if (e.code === 'Escape') { if (e.type === 'keydown') tell({ t: 'exit' }); e.preventDefault(); return; }
    if (codeMap[e.code]) { if (!e.repeat) postKey(e.type === 'keydown', e.code); e.preventDefault(); }
}
document.addEventListener('keydown', onKey);
document.addEventListener('keyup', onKey);

function point(kind, clientX, clientY) {
    const r = display.getBoundingClientRect();
    if (!r.width) return;
    evtQueue.queueEvent({
        kind,
        x: ((clientX - r.left) * display.width / r.width) | 0,
        y: ((clientY - r.top) * display.height / r.height) | 0
    });
}
let pressed = false;
display.addEventListener('pointerdown', e => { pressed = true; display.setPointerCapture(e.pointerId); point('pointerpressed', e.clientX, e.clientY); e.preventDefault(); });
display.addEventListener('pointermove', e => { if (pressed) point('pointerdragged', e.clientX, e.clientY); });
display.addEventListener('pointerup', e => { if (!pressed) return; pressed = false; point('pointerreleased', e.clientX, e.clientY); });
display.addEventListener('pointercancel', () => { pressed = false; });

addEventListener('message', e => {
    if (e.source !== parent) return;
    const m = e.data || {};
    if (m.t === 'run') { if (lib) run(m); else pending = m; }
    else if (m.t === 'key') postKey(!!m.down, m.code);
});

// ---- Java helpers (from the freej2me-web launcher)
async function javaToKv(map, kv) {
    const it = await (await map.entrySet()).iterator();
    while (await it.hasNext()) {
        const entry = await it.next();
        kv[await entry.getKey()] = await entry.getValue();
    }
}
async function kvToJava(kv) {
    const HashMap = await lib.java.util.HashMap;
    const map = await new HashMap();
    for (const k of Object.keys(kv)) await map.put(k, kv[k]);
    return map;
}

async function install(id, name, jar) {
    const util = await lib.pl.zb3.freej2me.launcher.LauncherUtil;
    const known = localStorage.getItem('larch:' + id);
    if (known && await cjFileBlob('/files/' + known + '/app.jar')) return known;

    status('Installing ' + name + '…');
    await util.resetTmpDir();
    const File = await lib.java.io.File;
    const jarFile = await new File('/files/_tmp/larch.jar');
    await util.copyJar(new Int8Array(jar), jarFile);

    const MIDletLoader = await lib.org.recompile.mobile.MIDletLoader;
    const loader = await MIDletLoader.getMIDletLoader(jarFile);
    if (!(await loader.getAppId())) {
        await util.ensureAppId(loader, name);
        loader.name = await loader.getAppId();
    }
    const appId = await loader.getAppId();

    const Config = await lib.org.recompile.freej2me.Config;
    const settings = {};
    await javaToKv(Config.DEFAULT_SETTINGS, settings);
    settings.width = '240';
    settings.height = '320';
    const Analyser = await lib.pl.zb3.freej2me.launcher.AnalyserUtil;
    const found = await Analyser.analyseFile(jarFile, name);
    if (found.screenWidth !== -1) { settings.width = found.screenWidth + ''; settings.height = found.screenHeight + ''; }
    if (found.phoneType) settings.phone = found.phoneType;

    const appProps = {};
    await javaToKv(loader.properties, appProps);
    await util.initApp(jarFile, loader, await kvToJava(settings), await kvToJava(appProps), await kvToJava({}));
    try { localStorage.setItem('larch:' + id, appId); } catch (e) {}
    return appId;
}

async function run(m) {
    try {
        const appId = await install(m.id, m.name || 'Application', m.jar);
        status('Starting ' + (m.name || 'application') + '…');
        const FreeJ2ME = await lib.org.recompile.freej2me.FreeJ2ME;
        FreeJ2ME.main(['app', appId]).catch(err => {
            try { err.printStackTrace(); } catch (e) {}
            tell({ t: 'error', text: 'The application closed unexpectedly' });
        });
    } catch (err) {
        console.error(err);
        tell({ t: 'error', text: 'This application could not be started' });
    }
}

async function boot() {
    status('Starting Java…');
    window.libmidi = new LibMidi(createUnlockingAudioContext());
    await window.libmidi.init();
    window.libmidi.midiPlayer.addEventListener('end-of-media', e => {
        evtQueue.queueEvent({ kind: 'player-eom', player: e.target });
    });
    window.libmedia = new LibMedia();

    await cheerpjInit({
        enableDebug: false,
        natives: {
            ...canvasFontNatives, ...canvasGraphicsNatives, ...gles2Natives,
            ...jsReferenceNatives, ...mediaBridgeNatives, ...midiBridgeNatives,
            async Java_pl_zb3_freej2me_bridge_shell_Shell_setTitle(lib, title) {},
            async Java_pl_zb3_freej2me_bridge_shell_Shell_setIcon(lib, iconBytes) {},
            async Java_pl_zb3_freej2me_bridge_shell_Shell_getScreenCtx(lib) { return screenCtx; },
            async Java_pl_zb3_freej2me_bridge_shell_Shell_setCanvasSize(lib, width, height) {
                screenCtx.canvas.width = width;
                screenCtx.canvas.height = height;
                if (!started) {
                    started = true;
                    msgBox.style.display = 'none';
                    display.style.display = 'block';
                    display.focus();
                    tell({ t: 'started' });
                }
                fit();
            },
            async Java_pl_zb3_freej2me_bridge_shell_Shell_waitForAndDispatchEvents(lib, listener) {
                const KeyEvent = await lib.pl.zb3.freej2me.bridge.shell.KeyEvent;
                const PointerEvent = await lib.pl.zb3.freej2me.bridge.shell.PointerEvent;
                const evt = await evtQueue.waitForEvent();
                if (evt.kind == 'keydown') await listener.keyPressed(await new KeyEvent(...evt.args));
                else if (evt.kind == 'keyup') await listener.keyReleased(await new KeyEvent(...evt.args));
                else if (evt.kind == 'pointerpressed') await listener.pointerPressed(await new PointerEvent(evt.x, evt.y));
                else if (evt.kind == 'pointerdragged') await listener.pointerDragged(await new PointerEvent(evt.x, evt.y));
                else if (evt.kind == 'pointerreleased') await listener.pointerReleased(await new PointerEvent(evt.x, evt.y));
                else if (evt.kind == 'player-eom') await listener.playerEOM(evt.player);
                else if (evt.kind == 'player-video-frame') await listener.playerVideoFrame(evt.player);
            },
            async Java_pl_zb3_freej2me_bridge_shell_Shell_restart(lib) { location.reload(); },
            async Java_pl_zb3_freej2me_bridge_shell_Shell_exit(lib) { tell({ t: 'exit' }); },
            async Java_pl_zb3_freej2me_bridge_shell_Shell_sthop(lib) {},
            async Java_pl_zb3_freej2me_bridge_shell_Shell_say(lib, sth) { console.log('[say]', sth); },
            async Java_pl_zb3_freej2me_bridge_shell_Shell_sayObject(lib, label, obj) { console.log('[sayobject]', label, obj); }
        }
    });

    lib = await cheerpjRunLibrary(webRoot + '/freej2me-web.jar');
    tell({ t: 'ready' });
    if (pending) { const m = pending; pending = null; run(m); }
}

boot().catch(err => {
    console.error(err);
    status('Java could not start. Check the internet connection.');
    tell({ t: 'error', text: 'Java could not start. Check the internet connection.' });
});
