# Detail Image Generator

Rails app for generating product detail images from uploaded source images,
fonts, and JSON/Excel task configuration.

## Production Storage

Production SQLite databases default to persistent `/data` paths:

```sh
/data/production.sqlite3
/data/production_cache.sqlite3
/data/production_queue.sqlite3
/data/production_cable.sqlite3
```

Active Storage `local` files are written under `/rails/storage`. The production
Compose stack mounts both `/data` and `/rails/storage` as named volumes so
generated images, uploaded images, uploaded fonts, ZIP files, and SQLite files
survive container restarts and redeploys.

## Production Environment

Copy `.env.prod.example` to `.env.prod` on the server and replace every
placeholder with real production values. Do not commit `.env.prod`.

Important variables:

- `APP_HOST`: public host, for example `detail-image.tudouke.com`.
- `SECRET_KEY_BASE` and `RAILS_MASTER_KEY`: production Rails secrets.
- `ACTIVE_STORAGE_SERVICE`: defaults to `local`.
- `SQLITE_*`: persistent SQLite database paths under `/data`.
- `CHROME_BIN` and `BROWSER_PATH`: Chromium path used by Ferrum.
- `ENABLE_BASIC_AUTH`: set to `true` to protect normal app pages.
- `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD`: production Basic Auth credentials.

## Local First-Time GitHub Setup

```sh
git remote add origin git@github.com:edward0127/detail_image_generator.git
git push -u origin main
```

## First Server Setup

The app is designed for the same single-container Docker Compose deployment
style as the TDK Group Rails app. The reverse proxy is handled outside this
repo.

```sh
mkdir -p /var/detail_image_generator
git clone git@github.com:edward0127/detail_image_generator.git /var/detail_image_generator
cd /var/detail_image_generator
cp .env.prod.example .env.prod
# edit .env.prod with real values
docker login ghcr.io
./script/deploy.sh deploy
```

The Compose service is `web`, the container is `detail_image_generator`, and the
app is bound on the host at `127.0.0.1:3015`. The Dockerfile exposes port `80`,
so Compose maps `127.0.0.1:3015:80`.

## Normal Redeploy

From a local checkout:

```sh
./script/deploy_production.sh --auto-commit "Deploy detail image generator"
```

Or manually on the server:

```sh
cd /var/detail_image_generator
git pull --ff-only
./script/deploy.sh deploy
```

## Useful Server Commands

```sh
./script/deploy.sh logs
./script/deploy.sh status
./script/deploy.sh restart
./script/deploy.sh down
```

The deploy script uses `http://127.0.0.1:3015/up` for its healthcheck.

## DNS And Nginx Notes

Do not modify live Nginx files from this app repo. Add DNS for the chosen
subdomain, for example:

```text
detail-image.tudouke.com A <server_public_ip>
```

or use a CNAME to an existing host pointing at the same server.

Example Nginx reverse proxy:

```nginx
server {
  listen 80;
  server_name detail-image.tudouke.com;

  client_max_body_size 100M;

  location / {
    proxy_pass http://127.0.0.1:3015;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
```

Issue SSL separately, for example with Certbot:

```sh
sudo certbot --nginx -d detail-image.tudouke.com
```

## Local Verification

```sh
bundle exec rails test
bundle exec rails zeitwerk:check
docker build -t detail_image_generator:test .
```

Do not start the Rails server as part of deployment verification.
