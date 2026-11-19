# DRAW ROOM（Linear おえかきルーム）

Linearのライバーが、スマホから同じキャンバスに同時に描けるお絵描きページです。ログインはDiscordで行い、LinearのDiscordサーバーで決めたロールを持つ人だけが入れます。運営は、誰がどの線を描いたかの確認、警告、BAN、線の削除ができます。

`config.js` が空のままなら、デモモードで動きます。デモモードはログインなしで、そのブラウザの中だけで試せます。

## ファイル

| ファイル | 中身 |
| --- | --- |
| `index.html` | アプリ本体 |
| `config.js` | 接続先のSupabaseの設定 |
| `supabase/migrations/20261119000000_drawroom.sql` | テーブル、アクセスルール、関数、Realtimeの設定 |
| `supabase/functions/verify-discord/index.ts` | Discordのロールを確かめるEdge Function |

## セットアップ

Supabaseの管理画面のメニュー名は、変わることがあります。

### 1. GitHub Pagesで公開する

1. リポジトリの Settings → Pages を開く
2. Source を「Deploy from a branch」、Branch を `main` と `/ (root)` にして保存する
3. 数分待つと、`https://isumiaki.github.io/draw-room/` で開けるようになる

この時点では、デモモードで動きます。

### 2. データベースを作る

1. Supabaseのプロジェクトで SQL Editor を開く
2. `supabase/migrations/20261119000000_drawroom.sql` の中身をすべて貼り付けて、Run を押す

何度実行しても、同じ状態になります。

### 3. DiscordのアプリとIDを用意する

1. [Discord Developer Portal](https://discord.com/developers/applications) で New Application を押してアプリを作る
2. OAuth2 の画面で、Client ID と Client Secret を控える
3. 同じ画面の Redirects に、次のURLを追加する

```
https://<プロジェクトのRef>.supabase.co/auth/v1/callback
```

`<プロジェクトのRef>` は、SupabaseのProject URL（`https://xxxx.supabase.co`）の `xxxx` の部分です。

次に、Discordのアプリで開発者モードをオンにします（ユーザー設定 → 詳細設定 → 開発者モード）。そのうえで、次の3つを控えます。

- LinearのサーバーのID：サーバー名を右クリック →「サーバーIDをコピー」
- ライバーのロールのID：サーバー設定 → ロール → ロールを右クリック →「ロールIDをコピー」
- 運営のロールのID：同じ方法でコピー

ロールが複数ある場合は、すべて控えます。

### 4. SupabaseでDiscordログインを有効にする

1. Authentication → Sign In / Providers → Discord を開き、有効にする
2. 手順3のClient IDとClient Secretを入れて保存する
3. Authentication → URL Configuration を開く
4. Site URL に `https://isumiaki.github.io/draw-room/` を入れる
5. Redirect URLs にも `https://isumiaki.github.io/draw-room/` を追加する

### 5. Edge Functionを公開する

1. Edge Functions → Deploy a new function → Via Editor を選ぶ
2. 名前を `verify-discord` にする
3. `supabase/functions/verify-discord/index.ts` の中身を貼り付けて、Deploy を押す
4. Edge Functions → Secrets で、次の4つを登録する

| 名前 | 値 |
| --- | --- |
| `DISCORD_GUILD_ID` | LinearのサーバーのID |
| `DISCORD_LIVER_ROLE_IDS` | ライバーのロールのID。複数あるときはカンマ区切り |
| `DISCORD_STAFF_ROLE_IDS` | 運営のロールのID。複数あるときはカンマ区切り |
| `ALLOWED_ORIGIN` | `https://isumiaki.github.io` |

Supabase CLIを使う場合は、`supabase functions deploy verify-discord` でも公開できます。

### 6. `config.js` に接続先を書く

Project Settings → API Keys（またはAPI）から、Project URLと公開用のキー（anon public、または Publishable key）をコピーして、`config.js` に書きます。

```js
window.DRAWROOM_CONFIG = {
  SUPABASE_URL: "https://xxxx.supabase.co",
  SUPABASE_ANON_KEY: "ここに公開用のキー"
};
```

公開用のキーは、ページに書いてよいキーです。`service_role` のキー（秘密のキー）とDiscordのClient Secretは、ここに書きません。

`main` にpushすると、数分でGitHub Pagesに反映されます。

### 7. 確かめる

1. 運営のロールを持つアカウントでログインし、IRIAM IDを入れて入室できるか
2. ロールのないアカウントで、「ロールがありません」の画面になるか
3. 2台以上で同時に描いて、相手の線が描いている途中から見えるか
4. 運営モード（右側の盾のボタン）で、線をタップすると描いた人が出るか
5. 警告とBANが、相手の画面にすぐ届くか

## 仕組みのメモ

- 参加できるかどうかは、ログインのたびにEdge Functionが判定します。判定の有効期限は30日で、切れたらログインし直してもらいます。期限は `is_member()` の `interval '30 days'` で変えられます
- キャンバスは毎日10:30（日本時間）に白紙に戻ります。消すのはSupabaseのpg_cronで、ジョブ名は `drawroom-daily-clear`、スケジュールは `30 1 * * *`（UTCの1:30）です。時刻を変えるときは、このスケジュールと `index.html` の `RESET_H` / `RESET_M` をそろえて変えてください。登録できたかは、Integrations → Cron で確かめられます
- 毎日のリセットで消えた線も `stroke_trash` に入り、14日たったものから消えます
- 消しゴムで消せるのは自分の線だけです。運営はすべての線を消せます
- 消しゴムや運営の削除で消えた線は、`stroke_trash` テーブルに残ります。消した操作を元に戻すときや、あとで確認するときに使います
- 運営の操作（警告、BAN、BAN解除、他の人の線の削除、IRIAM IDの修正）は、`mod_log` テーブルに残ります
- Supabaseの無料プランには、同時接続数とメッセージ数の上限があります。10人前後で同時に描いて上限に収まるかは、実際に試して確かめてください
