#!/bin/sh
set -eu

_exit() {
	printf '[rk-initrd-fix] error: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '[rk-initrd-fix] %s\n' "$*"
}

need_file() {
	[ -r "$1" ] || _exit "$1 is missing"
}

install_overlay() {
	root="$1"
	overlay="$(dirname "$0")/overlay"

	if [ ! -d "$overlay" ]; then
		log "overlay not found, skipping"
		return 0
	fi

	log "installing overlay files"
	cp -a "$overlay"/. "$root"/
	chmod 0755 "$root/usr/syno/bin/rk_bootanim" 2>/dev/null || true
	chmod 0755 "$root/usr/syno/sbin/rk3399_bootanim.sh" 2>/dev/null || true
}

install_bootanim_hook() {
	root="$1"
	linuxrc="$root/linuxrc.syno"
	impl="$root/linuxrc.syno.impl"
	hook='/bin/sh /usr/syno/sbin/rk3399_bootanim.sh'

	need_file "$linuxrc"
	[ -x "$root/usr/syno/sbin/rk3399_bootanim.sh" ] || return 0

	if [ -f "$impl" ] && grep -Fq "$hook" "$impl"; then
		grep -Fvx "$hook" "$impl" >"$impl.rk3399" || true
		mv -f "$impl.rk3399" "$impl"
		chmod 0755 "$impl"
	fi

	if grep -Fq "$hook" "$linuxrc"; then
		log "boot animation hook already installed"
		return 0
	fi

	log "installing boot animation hook"
	awk -v hook="$hook" '
		!started && $0 == "\tif RunWithLog /var/log/linuxrc.syno.log /linuxrc.syno.impl; then" {
			print "\t" hook
			print
			started = 1
			next
		}
		{ print }
		END {
			if (!started)
				exit 1
		}
	' "$linuxrc" >"$linuxrc.rk3399"
	mv -f "$linuxrc.rk3399" "$linuxrc"
	chmod 0755 "$linuxrc"
}

install_all_safeguards_hook() {
	root="$1"
	linuxrc="$root/linuxrc.syno.impl"
	script="$root/usr/syno/sbin/rk_boot_safeguard.sh"
	hook='/bin/sh /usr/syno/sbin/rk_boot_safeguard.sh "$Mnt"'

	need_file "$linuxrc"
	mkdir -p "$(dirname "$script")"

	cat >"$script" <<'EOF'
#!/bin/sh
# rk_boot_safeguard.sh - OEC-T/RK3566 鍏ㄩ摼璺‖浠跺姞鍥轰笌绯荤粺鑷剤
RootMnt="$1"
[ -n "$RootMnt" ] && [ -d "$RootMnt" ] || exit 0

set_synoinfo_kv() {
	file="$1"
	key="$2"
	value="$3"
	tmp="${file}.rksyno.$$"
	[ -f "$file" ] || return 0
	/bin/grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
	echo "${key}=\"${value}\"" >> "$tmp"
	/bin/mv -f "$tmp" "$file"
}

copy_model_dtb() {
	dir="$1"
	[ -d "$RootMnt/$dir" ] || return 0
	[ -f "/$dir/model.dtb" ] || return 0
	/bin/cp -f "/$dir/model.dtb" "$RootMnt/$dir/model.dtb"
}

# 1. 鍚屾 model.dtb 涓庡崟鐩樹綅閰嶇疆锛屽苟澹版槑 eMMC 鍚姩
max_disks="$(/bin/get_key_value /etc.defaults/synoinfo.conf maxdisks 2>/dev/null)"
[ -n "$max_disks" ] || max_disks=1

for dir in etc.defaults etc; do
	[ -d "$RootMnt/$dir" ] || continue
	copy_model_dtb "$dir"
	set_synoinfo_kv "$RootMnt/$dir/synoinfo.conf" maxdisks "$max_disks"
	set_synoinfo_kv "$RootMnt/$dir/synoinfo.conf" max_sys_raid_disks "$max_disks"
	set_synoinfo_kv "$RootMnt/$dir/synoinfo.conf" support_emmc_boot "yes"
	set_synoinfo_kv "$RootMnt/$dir/synoinfo.conf" support_led_brightness_adjustment "no"
done

# 2. 褰诲簳鎷︽埅 eMMC 鍒嗗尯鑷姩鎸傝浇涓烘闈?USB 绉诲姩纭洏
mkdir -p "$RootMnt/etc/udev/rules.d"
echo "# Masked: Disable MMC automount" > "$RootMnt/etc/udev/rules.d/50-mmc.rules"
if [ -f "$RootMnt/lib/udev/rules.d/50-mmc.rules" ]; then
	sed -i 's|^RUN+="/lib/udev/script/sdcard.sh|# RUN+="/lib/udev/script/sdcard.sh|' "$RootMnt/lib/udev/rules.d/50-mmc.rules" 2>/dev/null || true
fi
if [ -f "$RootMnt/lib/udev/script/sdcard.sh" ]; then
	if ! grep -q "exit 0" "$RootMnt/lib/udev/script/sdcard.sh"; then
		sed -i '2i # Disabled automount\nexit 0' "$RootMnt/lib/udev/script/sdcard.sh" 2>/dev/null || true
	fi
fi

# 3. 閮ㄧ讲 CPU 绋抽瀹堟姢锛堥攣瀹?1.608 GHz 闃叉 1.8G 娆犲帇姝绘満锛岃В缁?816M 闄嶉€熷崱姝伙級
mkdir -p "$RootMnt/usr/local/etc/rc.d"
cat << 'CPUEOF' > "$RootMnt/usr/local/etc/rc.d/Z99zz_cpugovernor.sh"
#!/bin/sh
POL=/sys/devices/system/cpu/cpufreq/policy0
apply() {
	[ -d "$POL" ] || return 1
	echo 1608000 > "$POL/scaling_max_freq" 2>/dev/null
	echo 816000 > "$POL/scaling_min_freq" 2>/dev/null
	echo schedutil > "$POL/scaling_governor" 2>/dev/null
}
case "$1" in
	start)
		apply
		( i=0; while [ $i -lt 12 ]; do sleep 5; apply; i=$((i+1)); done ) >/dev/null 2>&1 &
		;;
	*) apply ;;
esac
exit 0
CPUEOF
chmod 755 "$RootMnt/usr/local/etc/rc.d/Z99zz_cpugovernor.sh"

# 4. 閮ㄧ讲缁煎悎寮€鏈哄畧鎶よ繘绋嬶紙缃戠粶瀵规椂銆乀UN 缃戝崱銆丷KNPU 鍔犻€熴€侀偖浠舵ā鏉裤€佹洿鏂板睆钄斤級
cat << 'BGEOF' > "$RootMnt/usr/local/etc/rc.d/S99boot_safeguard.sh"
#!/bin/sh
case "$1" in
	start)
		# 缃戠粶瀵规椂锛堣В鍐虫棤 RTC 瀵艰嚧璇佷功澶辨晥銆侀偖浠跺彂閫佸け璐ワ級
		( ntpdate -u ntp.aliyun.com 2>/dev/null || ntpdate -u pool.ntp.org 2>/dev/null || true ) &

		# 琛ラ綈閫氱煡涓庨偖浠跺璇█妯℃澘杞摼鎺?		mkdir -p /var/cache/texts
		for d in /usr/syno/synoman/webman/texts/*; do
			[ -d "$d" ] && [ ! -e "/var/cache/texts/$(basename "$d")" ] && ln -sf "$d" "/var/cache/texts/$(basename "$d")"
		done

		# VPN TUN 铏氭嫙缃戝崱鏀寔 (Tailscale / Docker VPN)
		if [ ! -c /dev/net/tun ]; then
			mkdir -p /dev/net
			mknod /dev/net/tun c 10 200
			chmod 600 /dev/net/tun
		fi
		insmod /lib/modules/tun.ko 2>/dev/null || true

		# RKNPU & MPP 纭欢鍔犻€熻妭鐐瑰氨缁?		[ -e /dev/dri/card0 ] && ln -sf /dev/dri/card0 /dev/rknpu 2>/dev/null && chmod 666 /dev/dri/card0 /dev/rknpu 2>/dev/null || true
		[ -e /dev/mpp_service ] && chmod 666 /dev/mpp_service 2>/dev/null || true

		# 灞忚斀缇ゆ櫀鍥轰欢鏇存柊鍩熷悕锛堥槻姝㈠悗鍙拌鍗囩骇鍙樼爾锛?		for domain in update.synology.com update7.synology.com autoupdate.synology.com autoupdate7.synology.com; do
			grep -q "$domain" /etc/hosts || echo "127.0.0.1 $domain" >> /etc/hosts
		done

		# 淇鎺у埗闈㈡澘 CPU 鏄剧ず涓?RK3566 1.6 GHz
		mkdir -p /etc/syno_cpu
		echo "Rockchip, RK3566, (Cortex-A55), 4" > /etc/syno_cpu/syno_cpu_arch
		umount /proc/syno_cpu_arch 2>/dev/null || true
		mount --bind /etc/syno_cpu/syno_cpu_arch /proc/syno_cpu_arch 2>/dev/null || true
		echo 1600 > /proc/sys/kernel/syno_CPU_info_clock 2>/dev/null || true
		;;
esac
exit 0
BGEOF
chmod 755 "$RootMnt/usr/local/etc/rc.d/S99boot_safeguard.sh"

# 5. 灞忚斀缃戦〉鎺у埗闈㈡澘鐨勨€滄洿鏂板拰杩樺師鈥濆叆鍙?if [ -f "$RootMnt/usr/syno/synoman/webman/modules/AdminCenter/style.css" ]; then
	if ! grep -q "SAFEGUARD_HIDE_UPDATE" "$RootMnt/usr/syno/synoman/webman/modules/AdminCenter/style.css"; then
		cat << 'CSSEOF' >> "$RootMnt/usr/syno/synoman/webman/modules/AdminCenter/style.css"
/* SAFEGUARD_HIDE_UPDATE */
[syno-id*="Update_Reset"], [data-app*="Update_Reset"], .syno-admincenter-icon-Update_Reset, div[id*="Update_Reset"], .syno-update-reset { display: none !important; }
CSSEOF
	fi
fi
EOF
	chmod 0755 "$script"

	if ! grep -Fq "$hook" "$linuxrc"; then
		log "installing safeguard hook to linuxrc.syno.impl"
		awk -v hook="$hook" '
			!done && $0 == "if [ -f ${Mnt}/.noroot ]; then" {
				print hook
				print ""
				done = 1
			}
			{ print }
			END { if (!done) exit 1 }
		' "$linuxrc" >"$linuxrc.safeguard"
		mv -f "$linuxrc.safeguard" "$linuxrc"
		chmod 0755 "$linuxrc"
	fi
}

fix_webman_reboot() {
	root="$1"
	reboot_cgi="$root/usr/syno/web/webman/reboot.cgi"
	if [ -f "$reboot_cgi" ] && ! grep -Fq '/sbin/reboot -f' "$reboot_cgi"; then
		sed -i 's|^\([[:space:]]*\)reboot[[:space:]]*$|\1/sbin/reboot -f|' "$reboot_cgi"
	fi
}

main() {
	root="${1:-.}"
	soc="${SOC:-rk3399}"

	[ -d "$root" ] || _exit "$root is not a directory"

	case "$soc" in
		rk3399)
			install_overlay "$root"
			install_bootanim_hook "$root"
			;;
		*)
			log "skipping overlay and boot animation for $soc"
			;;
	esac
	install_all_safeguards_hook "$root"
	fix_webman_reboot "$root"
}

main "$@"