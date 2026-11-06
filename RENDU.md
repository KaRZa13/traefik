# TP5 — Reverse Proxy et Load Balancing avec Traefik — Rendu

## 0. Synthèse

| Élément | État |
| --- | --- |
| Traefik + 2 applications Nginx routées par nom d'hôte | ✅ |
| Découverte Docker avec `exposedByDefault: false` | ✅ |
| Load Balancing `app1` / `app1b` (round-robin) + health check | ✅ |
| Variante HTTPS avec CA locale, vérifiée **sans `curl -k`** | ✅ |
| Middlewares : redirection HTTPS + en-têtes de sécurité | ✅ |
| Recette automatisée `./tests.sh` | **16 PASS / 0 FAIL** |

### Arborescence finale

```
traefik-tp/
├── docker-compose.yml
├── config/
│   ├── traefik.yaml                  # configuration statique
│   └── dynamic/tls-middlewares.yaml  # configuration dynamique (provider file)
├── app1/index.html   app1b/index.html   app2/index.html
├── secrets/          # hors dépôt (.gitignore), hors répertoires Web
│   ├── ca/  (700)    ca.key (600) — jamais monté dans un conteneur
│   └── tls/          lab.crt, lab.key (600) — monté en :ro dans Traefik uniquement
├── tests.sh          # recette
└── .gitignore
```

### Écarts par rapport à l'énoncé (et pourquoi)

1. **Image `traefik:v3.6.2` au lieu de `v3.5.2`.** Incident rencontré : avec Docker Engine 29 (API min. 1.40), le provider Docker de Traefik v3.5.2 échoue en boucle :
   `client version 1.24 is too old. Minimum supported API version is 1.40`.
   Forcer `DOCKER_API_VERSION=1.44` a été tenté et **n'a aucun effet** sur v3.5.2. La v3.6.x négocie correctement la version d'API (`/v1.51/` visible dans les logs).
   → Symptôme côté utilisateur : *Incident 5 — dashboard vide* + 404 sur toutes les applis.
2. `log.level: INFO` en fin de TP (DEBUG utilisé pendant le diagnostic seulement).
3. Ajouts de durcissement : `no-new-privileges` sur tous les conteneurs, health check sur `app1`, options TLS (TLS ≥ 1.2, `sniStrict`), provider file pour les middlewares.

---

## 1. Preuves (sorties réelles)

**Routage par Host**
```
$ curl http://app2.localhost            → <h1>App2 - Bonjour depuis App2</h1>
$ curl -H "Host: app2.localhost" http://localhost → <h1>App2 - Bonjour depuis App2</h1>
$ curl -H "Host: evil.localhost" http://localhost → 404
```

**API — routers et services**
```
app1@docker        | Host(`app1.localhost`) | ['web']       | app1 | enabled   (+ middleware redirect-to-https@file)
app1-secure@docker | Host(`app1.localhost`) | ['websecure'] | app1 | enabled   (tls, security-headers@file)
app2@docker        | Host(`app2.localhost`) | ['web']       | app2 | enabled
app1@docker  servers: {'http://172.22.0.x:80': 'UP', 'http://172.22.0.y:80': 'UP'}
```

**Load Balancing (10 requêtes)** — alternance stricte :
```
App1 - Bonjour depuis App1
Bonjour depuis App1 - Instance B
App1 - Bonjour depuis App1
Bonjour depuis App1 - Instance B
...
```
Instance B gelée (`docker pause`) → le health check la passe `DOWN` en < 10 s, 6/6 requêtes en 200. Rétablie → `UP`.

**HTTPS**
```
$ curl --cacert secrets/ca/ca.crt https://app1.localhost   → 200, ssl_verify_result=0
$ curl https://app1.localhost                              → curl: (60) unable to get local issuer certificate
$ curl --tlsv1.1 --tls-max 1.1 ...                         → handshake refusé
$ curl -I http://app1.localhost                            → 301 Location: https://app1.localhost/  (308 en POST)
En-têtes : x-frame-options: DENY, x-content-type-options: nosniff, referrer-policy: no-referrer
```

**Tests de refus**
| Test | Résultat |
| --- | --- |
| Conteneur sur `frontend` **sans** `traefik.enable=true` mais avec une règle `Host(pirate.localhost)` | absent de l'API, 404 |
| Ports Nginx publiés (`docker port`) | aucun |
| Dashboard/API depuis une « machine tierce » (conteneur → IP LAN de l'hôte `:8080`) | connexion refusée (port lié à 127.0.0.1) |
| Même machine tierce → `:80` app1 | 200 (attendu : seule l'entrée applicative est publique) |
| Labels contenant mot de passe / clé / token | 0 |
| Socket Docker monté dans une application | non |

> Limite : le test « machine non autorisée » est simulé par un conteneur qui passe par l'IP LAN de l'hôte. Il doit être rejoué depuis une machine physique distincte pour être une preuve complète. Sous Linux, l'hôte lui-même peut joindre directement les IP du bridge (`172.22.0.x:80`) : ce n'est pas une exposition réseau externe, mais ça montre que « pas de port publié » ≠ « injoignable depuis l'hôte ».

---

## 2. Exercices

### Exercice 1 — Déploiement initial
Réseau `frontend` créé, Traefik déployé, dashboard sur `http://localhost:8080/dashboard/` (200). Ports en écoute : `0.0.0.0:80`, `0.0.0.0:443`, `127.0.0.1:8080`.

**Entrypoint vs router** : l'entrypoint est la *porte réseau* (adresse + port, ex. `:80`) où Traefik accepte des connexions. Le router est la *décision* : pour les requêtes arrivées sur un ou plusieurs entrypoints, il évalue une règle (`Host`, `PathPrefix`…) et choisit middlewares + service. Un entrypoint sert plusieurs routers ; un router peut écouter sur plusieurs entrypoints.

### Exercice 2 — Routage par nom d'hôte
Fait (voir preuves). Dashboard : routers `app1@docker`, `app2@docker` → services `app1@docker`, `app2@docker`, entrypoint `web`. Le suffixe `@docker` indique le provider d'origine.

### Exercice 3 — Load Balancing
Deux instances aux pages distinctes, deux backends `UP` dans `app1@docker`, alternance observée.

**LB ≠ routage par Host** : le routage choisit *quelle application* (décision sur le contenu de la requête : nom d'hôte). Le LB choisit *quelle instance* parmi les serveurs interchangeables d'une même application (décision sur la charge/la santé, indépendante du contenu). Ici les deux se cumulent : `Host(app1.localhost)` → service `app1` → nginx-app1 **ou** nginx-app1b.

### Exercice 4 — Sécurité
1. **`api.insecure: true`** expose API + dashboard sur l'entrypoint `traefik` (:8080) **sans authentification ni TLS**. Quiconque l'atteint obtient la cartographie complète : domaines, routes, IP internes, middlewares (donc les protections à contourner). Mitigé ici par la liaison à `127.0.0.1`.
2. **Socket Docker** : c'est l'API d'administration du démon, qui tourne en root. Qui y parle peut lancer un conteneur `--privileged` montant `/` de l'hôte → root sur l'hôte. `:ro` protège seulement le *fichier* socket contre l'écriture au niveau du système de fichiers, pas les requêtes API (`POST /containers/create` passe). Une compromission de Traefik = compromission de l'hôte.
3. **Protéger le dashboard** : `api.insecure: false` ; router dédié `Host(traefik.interne)` sur un entrypoint d'admin non public, `service=api@internal`, TLS, middlewares `ipAllowList` (réseau d'admin/VPN) + authentification (BasicAuth via `usersFile` ou mieux ForwardAuth/SSO) ; ne pas publier le port hors du VPN.
4. **`traefik.enable=true`** : principe d'autorisation explicite (*deny by default*). Sinon tout conteneur rattaché au réseau — base de données, outil interne, conteneur de debug — reçoit automatiquement une route publique. Démontré : le conteneur « pirate » sans ce label n'est pas routé.
5. **TLS activé vs certificat valide** : `tls=true` fait chiffrer la connexion ; sans certificat fourni, Traefik présente son certificat auto-signé par défaut → chiffré mais **non authentifié** (un attaquant en MITM peut présenter le sien). Un certificat valide est signé par une autorité que le client approuve et couvre le nom demandé (SAN) ; c'est ce que `curl` sans `-k` vérifie (`ssl_verify_result=0`).

### Exercice 5 — Évolution de l'architecture

```
                          Internet
                             │ 443 (80 → redirection)
                    ┌────────▼─────────┐
                    │     Traefik      │  TLS ≥1.2, certificats ACME
                    │ web / websecure  │  admin: entrypoint :8443 lié au VPN
                    └──┬──────┬─────┬──┘
     docker-socket-proxy│      │     │            ┌────────────── VPN / réseau admin
     (réseau "socket",  │      │     │            │   dashboard: Host(traefik.devtech.internal)
      internal, GET only)      │     │            │   ipAllowList + ForwardAuth (SSO)
                        │      │     │
   réseau net-shop ─────┤  net-blog  net-admin-app
          ┌─────────────┴─┐    │     │
          ▼               ▼    ▼     ▼
     shop-a          shop-b   blog   backoffice (auth obligatoire)
   (2 instances, health check, idéalement sur 2 hôtes)
```

Configuration statique (extrait) :
```yaml
api: { dashboard: true }            # insecure: false
entryPoints:
  web:
    address: ":80"
    http: { redirections: { entryPoint: { to: websecure, scheme: https } } }
  websecure: { address: ":443" }
  admin:     { address: "10.8.0.1:8443" }   # IP de l'interface VPN
providers:
  docker:
    endpoint: "tcp://socket-proxy:2375"     # tecnativa/docker-socket-proxy, CONTAINERS=1, POST=0
    exposedByDefault: false
  file: { directory: /etc/traefik/dynamic }
certificatesResolvers:
  le:
    acme:
      email: devops@devtech.example
      storage: /acme/acme.json             # 600, volume dédié, sauvegardé
      tlsChallenge: {}
```

Labels :
```yaml
shop-a / shop-b (mêmes noms de router/service) :
  - traefik.enable=true
  - traefik.docker.network=net-shop
  - traefik.http.routers.shop.rule=Host(`shop.devtech.example`)
  - traefik.http.routers.shop.entrypoints=websecure
  - traefik.http.routers.shop.tls.certresolver=le
  - traefik.http.routers.shop.middlewares=security-headers@file,ratelimit@file
  - traefik.http.services.shop.loadbalancer.server.port=80
  - traefik.http.services.shop.loadbalancer.healthcheck.path=/health
  - traefik.http.services.shop.loadbalancer.healthcheck.interval=5s

backoffice :
  - traefik.http.routers.bo.rule=Host(`bo.devtech.example`)
  - traefik.http.routers.bo.middlewares=sso@file,ipallow-office@file,security-headers@file

dashboard (sur le conteneur Traefik) :
  - traefik.http.routers.dash.rule=Host(`traefik.devtech.internal`)
  - traefik.http.routers.dash.entrypoints=admin
  - traefik.http.routers.dash.service=api@internal
  - traefik.http.routers.dash.tls=true
  - traefik.http.routers.dash.middlewares=ipallow-vpn@file,sso@file
```

Dynamique (file) :
```yaml
http:
  middlewares:
    sso:            { forwardAuth: { address: "http://authelia:9091/api/verify?rd=https://auth.devtech.example", trustForwardHeader: false } }
    basic-fallback: { basicAuth: { usersFile: /run/secrets/htpasswd } }   # jamais dans un label
    ipallow-vpn:    { ipAllowList: { sourceRange: ["10.8.0.0/24"] } }
    ratelimit:      { rateLimit: { average: 50, burst: 100 } }
    security-headers:
      headers: { stsSeconds: 31536000, contentTypeNosniff: true, frameDeny: true }   # HSTS une fois HTTPS durable
```

Disponibilité : health checks actifs (retrait automatique d'une instance), `restart: unless-stopped`, instances `shop` réparties sur ≥ 2 hôtes (Swarm/Kubernetes) avec ≥ 2 Traefik derrière une IP flottante/LB réseau, supervision (`metrics.prometheus`, alerte expiration certificats), sauvegarde de `acme.json` et des configs versionnées.

---

## 3. Questions de compréhension

1. **Reverse proxy** : serveur placé devant les applications qui reçoit les requêtes des clients et les relaie vers le bon backend ; le client ne voit que lui. (Le *forward proxy*, à l'inverse, est placé devant les clients et relaie vers Internet en leur nom.)
2. **Reverse proxy vs Load Balancer** : le reverse proxy *achemine* (point d'entrée, routage, TLS, middlewares) ; le LB *répartit* une charge entre plusieurs instances équivalentes. Traefik fait les deux ; un reverse proxy vers un seul backend ne fait pas de LB, et un LB L4 peut ne rien comprendre à HTTP.
3. **Rôle de Traefik avec Docker** : point d'entrée unique qui découvre les conteneurs via l'API Docker, construit routes et services à partir de leurs labels, termine TLS et répartit la charge, sans rechargement manuel.
4. **Statique vs dynamique** : statique = ce qui est lu au démarrage (entrypoints, providers, API, logs) et nécessite un redémarrage ; dynamique = routers/services/middlewares/TLS, rechargés à chaud depuis les providers.
5. **Provider** : source de configuration dynamique (Docker, Kubernetes, fichier, Consul…) que Traefik surveille.
6. **Entrypoint** : port/adresse d'écoute réseau (et protocole) par lequel le trafic entre dans Traefik.
7. **Router vs service** : le router décide (règle → middlewares → service) ; le service est la destination (liste de serveurs, LB, health check).
8. **Labels Docker** : ils attachent la configuration de routage au conteneur lui-même ; elle naît et disparaît avec lui, sans fichier central à éditer.
9. **`exposedByDefault: false`** : rien n'est exposé sans `traefik.enable=true` → pas d'exposition accidentelle d'un conteneur interne.
10. **Découverte** : Traefik écoute le flux d'événements de l'API Docker (`start`, `die`…), inspecte le conteneur, lit ses labels et son IP sur le réseau désigné, puis met à jour la configuration à chaud.
11. **Routage vs LB** : routage = choisir l'application selon la requête ; LB = choisir une instance au sein de cette application.
12. **Santé des backends** : sans health check, le LB continue d'envoyer du trafic à une instance morte ou bloquée → erreurs 502/timeouts pour une fraction des clients. Démontré : instance gelée retirée automatiquement.
13. **Protéger le dashboard** : il révèle toute la topologie (domaines, IP internes, middlewares) et sert de repérage à un attaquant ; selon la configuration, l'API peut aussi exposer des informations sensibles.
14. **Router TLS ≠ certificat valide** : `tls=true` active le chiffrement, mais sans certificat fourni Traefik sert un auto-signé « TRAEFIK DEFAULT CERT » que les clients refusent ; la validité dépend de la chaîne de confiance et du nom (SAN), pas du router.
15. **Nouvelle instance sans changer l'entrée client** : démarrer un conteneur portant les mêmes noms de router/service (ou `docker compose up --scale app1=3`) ; Traefik l'ajoute au service, l'URL ne change pas.
16. **`Host(...)` ≠ authentification** : l'en-tête `Host` est fourni par le client et falsifiable (`curl -H "Host: …"`) ; il sélectionne une route, il n'atteste pas l'identité ni les droits de quiconque.
17. **`docker.sock:ro`** : `:ro` s'applique au montage de fichier ; or écrire des requêtes dans un socket n'est pas une écriture de fichier. Toutes les opérations API restent possibles, y compris créer un conteneur privilégié. Il faut un proxy de socket filtrant.
18. **Protéger l'API autant que le dashboard** : le dashboard n'est qu'une interface au-dessus de l'API ; `curl /api/rawdata` donne les mêmes informations, en plus facilement automatisable.
19. **Réseau partagé vs segmentation** : sur `frontend`, toutes les applis se joignent entre elles (app2 peut appeler app1 directement en contournant Traefik). La segmentation place chaque application/niveau de confiance sur son réseau, Traefik étant le seul membre commun → limite le déplacement latéral.
20. **Deux instances sur un hôte ≠ HA** : elles partagent le même hôte, démon Docker, Traefik, disque, réseau et alimentation ; une panne de l'un de ces éléments coupe tout. La HA demande d'éliminer les points uniques (plusieurs hôtes, plusieurs proxies, données répliquées).
21. **Preuves d'un contrôle** : un test *négatif* reproductible depuis la bonne position (machine non autorisée → refus), le test positif correspondant (autorisé → accès), les journaux associés, et l'inspection de configuration (`docker port`, `docker inspect`, API). Un 404 isolé ne suffit pas : il faut savoir *pourquoi* la requête est refusée. → `tests.sh`.

---

## 4. Cartographie de sécurité — état vérifié dans le labo

| Composant / flux | Mesure en place dans le TP | Preuve | Reste à faire avant exposition (P1) |
| --- | --- | --- | --- |
| Clients → Traefik 80/443 | app1 en HTTPS (CA locale, TLS ≥ 1.2, sniStrict), redirection 301/308, en-têtes | `tests.sh` (sans `-k`) | app2 encore en HTTP ; CA publique/ACME ; HSTS |
| Admins → dashboard/API | lié à `127.0.0.1:8080` | refus depuis IP LAN | `api.insecure: false`, VPN + auth |
| Traefik → API Docker | socket monté dans Traefik seul | `docker inspect` des apps | proxy de socket filtrant |
| Traefik → App1/App1B | aucun port publié, health check | `docker port`, test `pause` | 2 hôtes pour la HA |
| Traefik → App2 | label explicite | conteneur non labellisé non routé | réseaux séparés par appli |
| Configs et labels | aucun secret dans les labels | grep des labels = 0 | revue de changements, dépôt Git |
| Certificats et secrets | `secrets/` hors Web, `.gitignore`, clé CA 600 non montée | `ls -l`, mounts | rotation, alerte d'expiration (cert. labo : 90 j, expire le 2027-02-04) |
| Images | versions figées (`traefik:v3.6.2`), `no-new-privileges` | compose | figer `nginx` par digest, scan (Trivy), Nginx non-root + rootfs RO |
| Journaux | niveau INFO | — | rotation, accès restreint, access logs filtrés |
| Hôte/instance Traefik | `restart: unless-stopped` | — | sauvegarde/restauration testée (P2) |

## 5. Reproduire

```bash
docker network create frontend   # si absent
cd traefik-tp && docker compose up -d
./tests.sh                       # 16 tests
# Navigateur : importer secrets/ca/ca.crt comme autorité de confiance pour https://app1.localhost
```
Nettoyage : `docker compose down && docker network rm frontend`.
