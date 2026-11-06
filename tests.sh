#!/usr/bin/env bash
# Recette TP5 — preuves fonctionnelles et de sécurité (aucun usage de curl -k pour valider TLS)
set -u
CA=secrets/ca/ca.crt
API=http://localhost:8080/api
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (attendu=$3 obtenu=$2)"; fail=$((fail+1)); fi; }
code() { curl -s -m 5 -o /dev/null -w "%{http_code}" "$@"; }

check "Traefik démarré"                       "$(docker inspect -f '{{.State.Running}}' traefik-1)" "true"
check "Dashboard accessible en local"         "$(code http://localhost:8080/dashboard/)" "200"
check "app1 en HTTPS (certificat vérifié)"    "$(curl -s --cacert $CA https://app1.localhost | grep -c App1)" "1"
check "app2 en HTTP"                          "$(curl -s http://app2.localhost | grep -c App2)" "1"
check "Redirection HTTP→HTTPS (GET → 301)"    "$(code http://app1.localhost)" "301"
check "Redirection HTTP→HTTPS (POST → 308)"   "$(code -X POST http://app1.localhost)" "308"
check "Host inconnu → 404"                    "$(code -H 'Host: inconnu.localhost' http://localhost)" "404"
check "Certificat rejeté sans CA de confiance" "$(curl -s -o /dev/null https://app1.localhost; echo $?)" "60"
check "TLS 1.1 refusé"                        "$(curl -s -o /dev/null --cacert $CA --tlsv1.1 --tls-max 1.1 https://app1.localhost; echo $?)" "35"
check "Aucun port Nginx publié"               "$(for c in nginx-app1 nginx-app1b nginx-app2; do docker port $c; done | wc -l)" "0"
check "Routers Docker = app1, app1-secure, app2" "$(curl -s $API/http/routers | grep -oE '"name":"[^"]+@docker"' | cut -d'"' -f4 | LC_ALL=C sort | paste -sd,)" 'app1-secure@docker,app1@docker,app2@docker'

docker run -d --rm --name tp5-unlabeled --network frontend -l 'traefik.http.routers.pirate.rule=Host(`pirate.localhost`)' nginx:stable >/dev/null; sleep 3
check "Conteneur sans traefik.enable non routé" "$(code -H 'Host: pirate.localhost' http://localhost)" "404"
docker rm -f tp5-unlabeled >/dev/null

HOSTIP=$(ip -4 route get 1.1.1.1 | grep -oP 'src \K\S+')
check "API/dashboard refusés depuis machine tierce ($HOSTIP)" "$(docker run --rm curlimages/curl:8.11.1 -s -m 5 -o /dev/null -w '%{http_code}' http://$HOSTIP:8080/api/rawdata)" "000"

check "2 backends UP dans le service app1"    "$(curl -s $API/http/services/app1@docker | grep -o '"UP"' | wc -l)" "2"
seen=$(for i in $(seq 1 10); do curl -s --cacert $CA https://app1.localhost; done | sort -u | wc -l)
check "Répartition sur 2 instances distinctes" "$seen" "2"

docker pause nginx-app1b >/dev/null; sleep 9
ok=$(for i in $(seq 1 6); do code --cacert $CA https://app1.localhost; echo; done | grep -c 200)
check "Instance B hors service : 6/6 requêtes OK (health check)" "$ok" "6"
docker unpause nginx-app1b >/dev/null

echo "---- $pass PASS / $fail FAIL"; [ $fail -eq 0 ]
