#!/usr/bin/env bash
#
# install-vaultwarden.sh — Déploiement de Vaultwarden via Docker (image officielle)
#
# PRÉREQUIS : Docker Engine doit être installé (voir install-docker-engine.sh).
#
# Usage :
#   sudo ./install-vaultwarden.sh
#   sudo ./install-vaultwarden.sh --data-dir /srv/vaultwarden --port 8080
#   sudo ./install-vaultwarden.sh --dry-run
#
# ⚠️  LIMITE IMPORTANTE À CONNAÎTRE AVANT DE LANCER :
#   Les applications Bitwarden officielles (extensions navigateur, mobile,
#   desktop) REFUSENT de se connecter à un serveur en HTTP, sauf si l'adresse
#   est exactement "localhost". Ce script démarre Vaultwarden en HTTP sur le
#   réseau local — cela suffit pour tester depuis le navigateur du serveur
#   lui-même ou via un tunnel SSH, mais PAS pour connecter vos applis
#   Bitwarden depuis un autre appareil. Pour un usage réel multi-appareils,
#   il vous faudra un reverse proxy avec un certificat TLS valide (Caddy ou
#   Nginx + Let's Encrypt, ce qui nécessite un nom de domaine). Ce n'est pas
#   inclus ici — dites-le-moi si vous voulez cette étape ensuite.

set -Eeuo pipefail

DATA_DIR="/srv/vaultwarden"
VW_PORT=8080
IMAGE="vaultwarden/server:latest"
CONFIGURE_FIREWALL=1
DRY_RUN=0
COMPOSE_DIR="/opt/vaultwarden"

if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'
  C_INFO=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()    { printf '%s [OK]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()   { trap - ERR; printf '%s[ERREUR]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
dry()   { printf '%s[dry-run]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

run() { if [[ "$DRY_RUN" -eq 1 ]]; then dry "$*"; else "$@"; fi; }

write_file() {
  local path="$1" content
  content="$(cat)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "écriture de $path :"
    printf '%s\n' "$content" | sed 's/^/           | /'
  else
    printf '%s\n' "$content" > "$path"
  fi
}

trap 'die "Échec à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir) DATA_DIR="${2:?chemin manquant}"; shift 2 ;;
    --port)     VW_PORT="${2:?port manquant}"; shift 2 ;;
    --no-firewall) CONFIGURE_FIREWALL=0; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Option inconnue : $1" ;;
  esac
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s[MODE SIMULATION]%s\n' "$C_WARN" "$C_OFF"
fi

info "Vérifications préalables"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  [[ "$DRY_RUN" -eq 1 ]] && warn "Pas root : vérifications limitées." || die "Lancez avec sudo."
fi

command -v docker >/dev/null 2>&1 || die "Docker n'est pas installé. Lancez d'abord install-docker-engine.sh."
docker compose version >/dev/null 2>&1 || die "Le plugin 'docker compose' est introuvable. Réinstallez Docker Engine avec install-docker-engine.sh."
ok "Docker et le plugin Compose sont disponibles"

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${VW_PORT}\$"; then
  die "Le port $VW_PORT est déjà occupé. Choisissez un autre port avec --port."
fi

if ! curl -fsSI --max-time 15 "https://hub.docker.com" >/dev/null 2>&1 && ! curl -fsSI --max-time 15 "https://registry-1.docker.io/v2/" >/dev/null 2>&1; then
  warn "Impossible de confirmer l'accès à Docker Hub — le téléchargement de l'image pourrait échouer."
fi

info "Installation des dépendances"
export DEBIAN_FRONTEND=noninteractive
run apt-get update -qq
run apt-get install -y -qq argon2

info "Préparation des répertoires"
run install -d -m 0750 "$DATA_DIR"
run install -d -m 0755 "$COMPOSE_DIR"

# ----------------------------------------------------------------------------
# Génération du jeton admin (ADMIN_TOKEN), affiché UNE SEULE FOIS
# ----------------------------------------------------------------------------
ADMIN_TOKEN_PLAIN=""
ADMIN_TOKEN_HASH=""
if [[ "$DRY_RUN" -eq 0 ]]; then
  info "Génération du jeton d'administration (panneau /admin)"
  ADMIN_TOKEN_PLAIN="$(openssl rand -base64 48 | tr -d '\n')"
  ARGON_SALT="$(openssl rand -base64 32)"
  # Paramètres identiques au preset "Bitwarden" du binaire vaultwarden
  # (m=65540 KiB, t=3, p=4) — voir la doc officielle :
  # https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page
  # On utilise l'outil 'argon2' du système plutôt que 'docker run ... hash',
  # car ce dernier attend un vrai terminal interactif (TTY) pour lire le mot
  # de passe et échoue silencieusement ou se bloque via un simple pipe.
  ADMIN_TOKEN_HASH="$(printf '%s' "$ADMIN_TOKEN_PLAIN" \
    | argon2 "$ARGON_SALT" -e -id -k 65540 -t 3 -p 4)"
  [[ -n "$ADMIN_TOKEN_HASH" && "$ADMIN_TOKEN_HASH" == \$argon2id\$* ]] \
    || die "Échec de la génération du hash admin via argon2. Vérifiez que le paquet 'argon2' est bien installé : apt install argon2"
  ok "Jeton admin généré et hashé (argon2id)"
else
  dry "génération du jeton admin (ignorée en simulation)"
  ADMIN_TOKEN_HASH='__PLACEHOLDER_HASH__'
  ADMIN_TOKEN_PLAIN='__PLACEHOLDER_PLAIN__'
fi

# ----------------------------------------------------------------------------
# docker-compose.yml
# ----------------------------------------------------------------------------
info "Génération du fichier docker-compose.yml"
# Docker Compose interprète lui-même les '$' dans son fichier YAML pour ses
# propres substitutions de variables — le hash argon2id en contient
# plusieurs (REDACTED_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx). Il faut les échapper en '$$' pour que
# Compose les traite comme des caractères littéraux, sinon le jeton est
# silencieusement corrompu au démarrage.
ADMIN_TOKEN_HASH_ESCAPED="${ADMIN_TOKEN_HASH//\$/\$\$}"
write_file "$COMPOSE_DIR/docker-compose.yml" <<EOF
services:
  vaultwarden:
    image: $IMAGE
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "http://127.0.0.1:${VW_PORT}"
      SIGNUPS_ALLOWED: "true"
      WEBSOCKET_ENABLED: "true"
      ADMIN_TOKEN: "${ADMIN_TOKEN_HASH_ESCAPED}"
    volumes:
      - ${DATA_DIR}:/data
    ports:
      - "${VW_PORT}:80"
EOF

cat > /dev/null <<'NOTE'
Le port est publié sur toutes les interfaces (0.0.0.0), ce qui couvre à la
fois l'accès localhost strict (accepté par les clients Bitwarden sans TLS,
puisque 0.0.0.0 inclut 127.0.0.1) ET l'accès LAN par IP (utile pour tester
depuis un navigateur, mais refusé par les vraies applis Bitwarden sans
HTTPS). Un double mapping séparé (127.0.0.1:PORT + PORT) chevaucherait
et ferait échouer Docker au démarrage : à éviter.
NOTE

# ----------------------------------------------------------------------------
# Lancement
# ----------------------------------------------------------------------------
info "Démarrage du conteneur Vaultwarden"
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "cd $COMPOSE_DIR && docker compose up -d"
else
  (cd "$COMPOSE_DIR" && docker compose up -d)
fi

READY=0
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "attente du port $VW_PORT (ignorée en simulation)"
else
  info "Attente du démarrage sur le port $VW_PORT…"
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:${VW_PORT}/"; then
      READY=1; break
    fi
    sleep 1
  done
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  :
elif [[ "$READY" -eq 1 ]]; then
  ok "Vaultwarden répond sur http://127.0.0.1:${VW_PORT}"
else
  warn "Vaultwarden ne répond pas encore. Diagnostic :
      cd $COMPOSE_DIR && docker compose logs -f"
fi

if [[ "$CONFIGURE_FIREWALL" -eq 1 ]] && command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "^Status: active"; then
    info "Ouverture du port Vaultwarden dans UFW (réseau local uniquement recommandé)"
    run ufw allow "${VW_PORT}/tcp" comment 'Vaultwarden - acces web'
    ok "Règle UFW appliquée"
  fi
fi

IP_LAN="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP_LAN="${IP_LAN:-<ip-du-serveur>}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF

────────────────────────────────────────────────────────────────
 Simulation terminée — rien n'a été modifié
────────────────────────────────────────────────────────────────
EOF
  exit 0
fi

cat <<EOF

────────────────────────────────────────────────────────────────
 ${C_OK}Vaultwarden installé${C_OFF}
────────────────────────────────────────────────────────────────
 Données      : $DATA_DIR
 Compose file : $COMPOSE_DIR/docker-compose.yml
 Port         : $VW_PORT

 ${C_INFO}Accès (depuis le serveur lui-même ou un tunnel SSH)${C_OFF}
   http://127.0.0.1:${VW_PORT}

 ${C_WARN}Jeton d'administration (panneau /admin) — À NOTER MAINTENANT${C_OFF}
   $ADMIN_TOKEN_PLAIN
   Ce jeton en clair n'est affiché qu'une seule fois et n'est stocké
   nulle part par ce script. Seul son hash argon2id est dans le
   docker-compose.yml. Si vous le perdez, régénérez-en un nouveau.

 ${C_WARN}Rappel important${C_OFF}
   Les applis Bitwarden (mobile, extensions) n'accepteront PAS
   http://${IP_LAN}:${VW_PORT} — seulement "localhost" ou une adresse
   HTTPS valide. Pour un accès multi-appareils, il faut un reverse
   proxy avec certificat TLS (nécessite un nom de domaine).

 ${C_INFO}Commandes utiles${C_OFF}
   cd $COMPOSE_DIR && docker compose logs -f
   cd $COMPOSE_DIR && docker compose restart
   cd $COMPOSE_DIR && docker compose down     (données conservées dans $DATA_DIR)
────────────────────────────────────────────────────────────────
EOF
