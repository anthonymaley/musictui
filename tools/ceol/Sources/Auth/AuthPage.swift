import Foundation

struct AuthPage {
    func generate(developerToken: String) throws -> String {
        let path = NSString(string: "~/.config/ceol/auth.html").expandingTildeInPath
        let html = """
        <!DOCTYPE html>
        <html><head><title>Ceol — Apple Music Auth</title>
        <script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js"></script>
        </head><body style="font-family:system-ui;max-width:600px;margin:40px auto;text-align:center">
        <h2>Ceol — Apple Music Authorization</h2>
        <p>Click to sign in and get your user token.</p>
        <button id="auth" style="font-size:18px;padding:12px 24px;cursor:pointer">Sign In</button>
        <div id="status" style="margin-top:20px"></div>
        <textarea id="token-output" style="display:none;width:100%;height:80px;font-size:12px;margin-top:10px" onclick="this.select()" readonly></textarea>
        <p id="instructions" style="display:none">Copy the token above, then run:<br><code>ceol auth set-token PASTE_HERE</code></p>
        <script>
        document.addEventListener('musickitloaded', async () => {
            const music = await MusicKit.configure({
                developerToken: '\(developerToken)',
                app: { name: 'ceol', build: '1.0' }
            });
            document.getElementById('auth').onclick = async () => {
                const statusEl = document.getElementById('status');
                const tokenEl = document.getElementById('token-output');
                const instrEl = document.getElementById('instructions');
                try {
                    await music.authorize();
                    const token = music.musicUserToken;
                    statusEl.textContent = 'Success! Copy this token:';
                    statusEl.style.color = 'green';
                    statusEl.style.fontWeight = 'bold';
                    tokenEl.value = token;
                    tokenEl.style.display = 'block';
                    instrEl.style.display = 'block';
                } catch(e) {
                    statusEl.textContent = 'Error: ' + e;
                    statusEl.style.color = 'red';
                }
            };
        });
        </script></body></html>
        """
        try FileManager.default.createDirectory(atPath: AuthManager.configDir, withIntermediateDirectories: true)
        try html.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
