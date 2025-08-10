#!/bin/bash

# print all keys/values from Redis
# for containerized redis run as such:
#   cat redis2txt.sh | docker exec -i immich_redis bash

# shellcheck disable=SC2016
two_lines_to_kv='{ sub(/^[0-9]+\) /, "") ; if (NR % 2) { key = $0 } else { print key ": " $0 } }'
xrange_to_csv='/^[0-9]+-[0-9]+$/ { if (NR > 1) print output ; output = "id=" $0 ; next }
            { if (!key) { key = $0 } else { output = output ", " key "=" $0 ; key = "" } }
            END { print output }'
print_consumer_groups=''

redis-cli --scan --pattern '*' | sort | while read -r key; do
  type=$(redis-cli type "$key")
  echo -e "\n==== $key ($type) ===="
  case $type in
    "string") redis-cli get "$key" ;;
    "list")   redis-cli lrange "$key" 0 -1 ;;
    "set")    redis-cli smembers "$key" ;;
    "zset")   redis-cli zrange "$key" 0 -1 withscores | awk "$two_lines_to_kv" ;;
    "hash")   redis-cli hgetall "$key" | awk "$two_lines_to_kv" ;;
    "stream") redis-cli xrange "$key" - + | awk "$xrange_to_csv"
      if [[ ! -z $print_consumer_groups ]] ; then
        echo -e "\n[Consumer Groups]"
        redis-cli xinfo groups "$key"
        redis-cli xinfo groups "$key" | awk '/name/ {print $2}' | while read -r group; do
          echo -e "\nGroup: $group"
          redis-cli xinfo consumers "$key" "$group"
        done
      fi ;;
    *) echo "Unsupported: $type" ;;
  esac
done
