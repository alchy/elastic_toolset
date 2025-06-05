#!/bin/bash

# --- Konfigurace skriptu ---
# Cesta k souboru s proměnnými prostředí (credentials)
ENV_FILE="/vzpelk/site/.env"

# Elasticsearch host
ES_HOST="https://clcsec.dc.vzp.cz:9200"

# Cesta k CA certifikátu pro curl
CA_CERT="/etc/kibana/kibana-certs/ca.pem"

# Regex pro filtrování aliasů, které chceme kontrolovat (uživatelské indexy)
# Předpokládá se, že uživatelské aliasy NIKDY nezačínají tečkou (.).
# Upravte tento regex tak, aby odpovídal vašim skutečným aliasům pro rollover.
ROLLOVER_ALIAS_REGEX="syslog-(apm|afm|unix|net|gtm|ips|proxy|asm)|winlogbeat|auditbeat|ntl|crp-ntl-tran|ntl-error|crp-ntl-secure|crp-ntl-securegdpr"

# --- Inicializace a nastavení ---

echo "=== Kontrola stavu Rollover Indexů a Dokumentů: $(date) ==="

# Kontrola existence .env souboru a načtení creds
if [ ! -f "${ENV_FILE}" ]; then
  echo "Chyba: Soubor .env nenalezen na ${ENV_FILE}. Ukončuji skript."
  exit 1
fi
source "${ENV_FILE}"

# Kontrola, zda jsou ELASTIC_USERNAME a ELASTIC_PASSWORD definovány
if [ -z "${ELASTIC_USERNAME}" ] || [ -z "${ELASTIC_PASSWORD}" ]; then
  echo "Chyba: ELASTIC_USERNAME nebo ELASTIC_PASSWORD nejsou nastaveny v ${ENV_FILE}. Ukončuji skript."
  exit 1
fi

# Curl možnosti s autentizací a certifikátem (tichý režim)
CURL_OPTS="-u ${ELASTIC_USERNAME}:${ELASTIC_PASSWORD} --cacert ${CA_CERT} -s"

# Dočasný soubor pro uložení JSON výstupu z aliasů
TEMP_ALIASES_DATA=$(mktemp)
trap "rm -f ${TEMP_ALIASES_DATA}" EXIT # Úklid dočasného souboru

# --- Získání dat o aliasech ---

echo "Načítám informace o aliasech z Elasticsearch..."
# Získání informací o všech aliasech
curl ${CURL_OPTS} -X GET "${ES_HOST}/_cat/aliases?format=json" > "${TEMP_ALIASES_DATA}"
if [ $? -ne 0 ]; then
  echo "Chyba: Selhalo načtení aliasů z Elasticsearch. Zkontrolujte připojení nebo oprávnění."
  exit 1
fi

# --- Zpracování dat a výstup ---

echo ""
echo "-----------------------------------------------------------------------------------------------------"
printf "%-25s %-35s %-15s %-15s\n" "Alias" "Aktivní Write Index" "Dokumentů" "Velikost (MB)"
echo "-----------------------------------------------------------------------------------------------------"

# Projdeme všechny aliasy a zkontrolujeme ty relevantní
# Filtr (.alias | startswith(\".\") | not) zajišťuje ignorování interních aliasů
jq -r \
  ".[] | select(
    (.alias | type == \"string\") and
    (.is_write_index | type == \"string\") and
    (.is_write_index == \"true\") and
    (.alias | startswith(\".\") | not) and
    (.alias | test(\"${ROLLOVER_ALIAS_REGEX}\"))
  ) | \"\(.alias)|\(.index)\"" "${TEMP_ALIASES_DATA}" | \
while IFS='|' read -r ALIAS ACTIVE_WRITE_INDEX; do
  # Získáme statistiky pro aktuální aktivní write index pomocí _stats API
  # OPRAVENO: Změněno z /_docs na /docs
  INDEX_STATS_JSON=$(curl ${CURL_OPTS} -X GET "${ES_HOST}/${ACTIVE_WRITE_INDEX}/_stats/store,docs" | jq -c '.')

  DOC_COUNT="N/A"
  STORE_SIZE="N/A"

  if [ -n "${INDEX_STATS_JSON}" ]; then
    # Získání počtu dokumentů
    # Použijeme `? // 0` pro vrácení 0, pokud je hodnota null nebo nenalezena
    DOC_COUNT=$(echo "${INDEX_STATS_JSON}" | jq -r --arg index_name "${ACTIVE_WRITE_INDEX}" '
      .indices[$index_name].total.docs.count? // 0
    ' 2>/dev/null)

    # Získání velikosti úložiště v MB
    # Použijeme `? // 0` pro vrácení 0, pokud je hodnota null nebo nenalezena
    RAW_STORE_SIZE_BYTES=$(echo "${INDEX_STATS_JSON}" | jq -r --arg index_name "${ACTIVE_WRITE_INDEX}" '
      .indices[$index_name].total.store.size_in_bytes? // 0
    ' 2>/dev/null)

    # Převod na MB a zaokrouhlení
    # Použijeme `0` jako default pro `bc` pokud je hodnota prázdná nebo nečíselná
    if [[ "${RAW_STORE_SIZE_BYTES}" =~ ^[0-9]+$ ]] && [ "${RAW_STORE_SIZE_BYTES}" -gt 0 ]; then
      STORE_SIZE=$(echo "scale=0; ${RAW_STORE_SIZE_BYTES} / (1024*1024)" | bc -l)
      # Zaokrouhlení nahoru, pokud je zbytek
      if (( $(echo "${RAW_STORE_SIZE_BYTES} % (1024*1024)" | bc) > 0 )); then
        STORE_SIZE=$((STORE_SIZE + 1))
      fi
    elif [ "${RAW_STORE_SIZE_BYTES}" -eq 0 ]; then
      STORE_SIZE="0"
    fi
  fi

  printf "%-25s %-35s %-15s %-15s\n" "${ALIAS}" "${ACTIVE_WRITE_INDEX}" "${DOC_COUNT}" "${STORE_SIZE}"
done

echo "-----------------------------------------------------------------------------------------------------"
echo "Kontrola dokončena."
echo "Poznámka: 'Velikost (MB)' je velikost úložiště (store.size) indexu zaokrouhlená na celé MB."

exit 0
