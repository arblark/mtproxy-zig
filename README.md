# mtproxy-zig installer

Test project — one-line installer script for [mtproto.zig](https://github.com/sleep3r/mtproto.zig) on a fresh Ubuntu/Debian VPS.

## Usage

```bash
curl -sSfL https://raw.githubusercontent.com/arblark/mtproxy-zig/main/install-mtproxy.sh | sudo bash
```

With Cloudflare IPv6 hopping:

```bash
curl -sSfL ... | sudo CF_TOKEN=xxx CF_ZONE=yyy bash
```

## Management

After install, use the `mtproxy` command:

```
mtproxy status       — service status
mtproxy restart      — restart all
mtproxy logs         — live logs
mtproxy link         — show tg:// connection links
mtproxy add-user X   — add user
mtproxy uninstall    — full removal
```
