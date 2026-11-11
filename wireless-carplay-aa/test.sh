#!/bin/sh
# Off-car test of the Wireless mod on the patch engine, against a car's real
# stock files (kept privately: STOCK, default ~/hmg-private/stock/ev6 with app/,
# lib/, onebin/, permissions/). Every part on: each rebuilt file must match the
# set's expect list (the engine checks), props go live, nothing touches
# build.prop; restore must give back every stock byte.
# Runs with the HMG-API mod SDK (HMGAPI_SDK, set by the mod workflow).
#   HMGAPI_SDK=<sdk> wireless-carplay-aa/test.sh [stock dir] [product] [onebin]
set -e
M=$(cd "$(dirname "$0")" && pwd)
S=${1:-$HOME/hmg-private/stock/ev6}
export HMGAPI_PRODUCT=${2:-CVEV.USA.0000.V015.012.260507}
export HMGAPI_ONEBIN=${3:-cvev_us}
PRODUCT=$HMGAPI_PRODUCT ONEBIN=$HMGAPI_ONEBIN
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$T/root
. "${HMGAPI_SDK:?set HMGAPI_SDK to the unpacked HMG-API mod SDK}/test/lib.sh"
# its NEMESIS package refuses the NEMESIS packages that change what it changes (mod.json "nemesis_conflicts")
d=$(HMGAPI_NEMESIS_CONFLICTS=/dev/null python3 "$HMGAPI_SDK/bin/nemesis-meta.py" depends hmgapi.wireless-carplay-aa 'hmgapi@>=1.0' --mod "$M/mod.json")
if [ "$d" = "hmgapi@>=1.0,!wireless.projection,!projection.tbt" ]; then echo "ok    NEMESIS package refuses wireless.projection and projection.tbt"
else echo "FAIL  NEMESIS package depends: [$d]"; exit 1; fi

# Manifest checks run even without a maintainer's private stock tree.
check "CEEV USA 260903 is supported" 1 "$(jq '[.system[] | select((.model == "CEEV" or (.model | arrays and index("CEEV"))) and .region == "USA" and .firmware == "260903" and (.features | index("hmgapi.wifi")))] | length' "$M/mod.json")"
check "CEEV USA uses the validated EV patch set" ev6 "$(jq -r '.cars["CEEV.USA."]' "$M/patches.json")"
check "CEEV Android Auto turn-by-turn recipe is included" 1 "$(jq '[.hooks.native["libautoreceiver_infobank.so"][] | select(. == "recipes/aa-tbt-dbfe7bd2.recipe")] | length' "$M/mod.json")"
CEEV_TBT=$M/recipes/aa-tbt-dbfe7bd2.recipe
check "CEEV TBT hooks routeMessage's unknown-message path" \
    "branch 0xb7f38 0x0" "$(grep '^branch ' "$CEEV_TBT")"
check "CEEV TBT returns to routeMessage cleanup" \
    "rel32 0x50 0x40 0xb7f3d" "$(grep '^rel32 0x50 ' "$CEEV_TBT")"
check "CEEV TBT uses its callback thunks and string helpers" \
    "rel32 0x40 0x40 0xa7211
rel32 0x44 0x40 0xa715b
rel32 0x48 0x40 0xa679d
rel32 0x4c 0x40 0xa7efd" "$(grep '^rel32 0x4[048c] ' "$CEEV_TBT")"
check "wireless Android Auto opens GPM's IPv4 hotspot port" 1 "$(jq '[.network.rules[] | select(.chain == "input" and .in == "hotspot" and .ip == 4 and .proto == "tcp" and .ports == [40515] and .action == "accept" and (has("when") | not))] | length' "$M/mod.json")"
check "wireless CarPlay mirrors the wired hotspot ports while its bridge is on" 1 "$(jq '[.network.rules[] | select(.chain == "input" and .in == "hotspot" and .proto == "tcp+udp" and .ports == ["5000-5001", 5020, "6000-6003", 6011, 6020, 6030, 7000] and .both_ways == true and .action == "accept" and .when == "settings.bridge")] | length' "$M/mod.json")"
check "wireless CarPlay allows hotspot ICMPv6 while its bridge is on" 1 "$(jq '[.network.rules[] | select(.chain == "input" and .in == "hotspot" and .proto == "icmpv6" and .action == "accept" and .when == "settings.bridge")] | length' "$M/mod.json")"
[ -d "$S/app" ] || { echo "no stock tree at $S (stock-file checks skipped)"; exit $fail; }

mkdir -p $R/system/app $R/system/lib $R/system/etc/permissions $R/system/onebin/$ONEBIN $R/sys/bus/sdio/devices/mmc1:0001:1 $R/data/hmgapi/mods $R/data/hmgapi/settings
cp $S/app/* $R/system/app/; cp $S/lib/* $R/system/lib/
cp $S/onebin/$ONEBIN/featurexml.cfg $R/system/onebin/$ONEBIN/
[ -d $S/permissions ] && cp $S/permissions/* $R/system/etc/permissions/
printf 'ro.build.product=%s\npersist.ium.support=none\n' "$PRODUCT" > $R/system/build.prop
printf 'ro.build.product=%s\nro.board.platform=tcc803x\nro.build.version.release=4.4.2\nro.mobis.onebindir=%s\n' "$PRODUCT" "$ONEBIN" > $R/props.txt
install_mod "$M"
BEFORE=$(tree)

eng plan
check "plan has no problems" 0 $rc
[ $rc = 0 ] || echo "$out"
has "plan opens GPM's wireless Android Auto port on the hotspot" \
    "network  firewall filter input: accept tcp port 40515 in hotspot (IPv4, 1 rule) [wireless-carplay-aa]" "$out"
has "plan opens the wireless CarPlay ports on the hotspot" \
    "network  firewall filter input: accept tcp+udp port 5000-5001,5020,6000-6003,6011,6020,6030,7000 (either way) in hotspot (IPv4+6, 56 rules) (when settings.bridge) [wireless-carplay-aa]" "$out"
eng apply
check "apply (every part)" 0 $rc
[ $rc = 0 ] || echo "$out"
NET_RULES=$(cat "$R/data/hmgapi/state/net.rules")
has "wireless Android Auto reaches GPM through the stock firewall" \
    "ipt 4 filter HMGAPI_IN -i wlan0 -s 192.168.0.0/24 -p tcp --dport 40515 -j ACCEPT" "$NET_RULES"
has "wireless CarPlay TCP reaches the hotspot" "-p tcp --dport 5000:5001 -j ACCEPT" "$NET_RULES"
has "wireless CarPlay UDP reaches the hotspot" "-p udp --dport 5000:5001 -j ACCEPT" "$NET_RULES"
has "wireless CarPlay IPv6 discovery reaches the hotspot" "-p icmpv6 -j ACCEPT" "$NET_RULES"
check "turn-by-turn GPM is hooks now: GPM untouched" "" "$(echo "$out" | grep HKMC_GPM)"
check "AA and CarPlay libraries are patched in memory now: files untouched" "" "$(echo "$out" | grep 'libautoreceiver\|libCarPlay')"
has "audio converter added" "/system/lib/libleafiaaac.so" "$out"
check "menu fix is a hook now: BtSettings untouched" "" "$(echo "$out" | grep HKMC_BtSettings)"
has "props live" "prop/persist.ium.support=carplay" "$(cat $R/settings.txt)"
has "bridge props live" "prop/persist.iap2.iden.wireless=t" "$(cat $R/settings.txt)"
check "build.prop untouched" "persist.ium.support=none" "$(grep persist.ium $R/system/build.prop)"
has "feature flag: CarPlay wireless file" '<feature name="com.hkmc.software.connectivity.carplay_wireless" />' "$(cat $R/system/etc/permissions/com.hkmc.software.connectivity.carplay_wireless.xml 2>/dev/null)"
has "featurexml: AA wireless line commented" "#-/system/etc/permissions/com.hkmc.software.connectivity.androidauto_wireless.xml" "$(cat $R/system/onebin/$ONEBIN/featurexml.cfg)"
check "turn-by-turn and bridge are hooks now: DiPO untouched" "" "$(echo "$out" | grep HKMC_DiPO)"

printf '{"bridge": false}\n' > $R/data/hmgapi/settings/wireless-carplay-aa.json
eng apply
check "settings change rebuilds" 0 $rc
[ $rc = 0 ] || echo "$out"
NET_RULES=$(cat "$R/data/hmgapi/state/net.rules")
has "bridge off: Android Auto's GPM port stays open" "--dport 40515 -j ACCEPT" "$NET_RULES"
check "bridge off: CarPlay ports are closed" "" "$(echo "$NET_RULES" | grep -- '--dport 5000' || true)"
check "bridge off: CarPlay ICMPv6 is closed" "" "$(echo "$NET_RULES" | grep -- '-p icmpv6' || true)"
check "no Wi-Fi client feature" no "$([ -f $R/system/etc/permissions/android.hardware.wifi.xml ] && echo yes || echo no)"
has "bridge off: its props back" "prop/persist.ium.support=carplay" "$(cat $R/settings.txt)"
check "bridge off: iap2 prop gone" "" "$(grep iap2.iden $R/settings.txt || true)"

eng restore
check "restore exit" 0 $rc
check "/system byte-identical to stock" "$BEFORE" "$(tree)"
check "props back to stock" "" "$(cat $R/settings.txt)"
exit $fail
