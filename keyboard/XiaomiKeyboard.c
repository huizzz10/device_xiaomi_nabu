/*
 * Copyright (C) 2026 Neokoni <dulin081682@126.com>
 *
 * SPDX-License-Identifier: MIT
 *
 * Xiaomi Pad 5 (nabu) magnetic keyboard attach-state gate
 *
 * Manages the keyboard bridge MCU (USB 3206:3FFC) by:
 *   1. Polling MCU connect state via vendor bulk protocol
 *   2. Gating HID interfaces to control IME/pointer visibility
 *
 * Uses usbfs for device discovery, state query, and interface control.
 */

#define LOG_TAG "XiaomiKeyboard"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <linux/usbdevice_fs.h>
#include <linux/usb/ch9.h>
#include <android/log.h>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

#define BRIDGE_VID 0x3206
#define BRIDGE_PID 0x3FFC

#define USBDEVFS_PATH "/dev/bus/usb"

#define POLL_MS 1000
#define WAIT_MS 100 /* device-absent poll: covers the screen-on re-discovery */
#define FAST_WAIT_MS 50 /* fast re-discovery poll right after device loss */
#define FAST_WINDOW_MS 3000 /* keep fast polling for this long after loss */
#define IO_TIMEOUT_MS 500

/* Stock frame: 4E 31 80 38 A1 01 01 <sum>, sum = plain byte sum [0..6] */
static const uint8_t kGetConnectState[8] = {
	0x4E, 0x31, 0x80, 0x38, 0xA1, 0x01, 0x01, 0xDA,
};

enum attach {
	ATTACH_UNKNOWN = -1,
	ATTACH_DETACHED = 0,
	ATTACH_ATTACHED = 1,
};

struct kbdev {
	char path[64];   /* /dev/bus/usb/BBB/DDD */
	int kbd_if;      /* boot keyboard interface number, -1 if none */
	int mouse_if;    /* boot mouse interface number, -1 if none */
	int cmd_if;      /* interface with IN+OUT endpoints */
	uint8_t out_ep;  /* OUT endpoint address */
	uint8_t in_ep;   /* IN endpoint address */
	int fd;          /* usbfs fd, -1 when not open */
};

static void msleep(int ms)
{
	usleep((useconds_t)ms * 1000);
}

static int get_descriptor(int fd, uint16_t type_idx, uint16_t index,
			  void *data, uint16_t len)
{
	struct usbdevfs_ctrltransfer c = {
		.bRequestType = USB_DIR_IN | USB_TYPE_STANDARD | USB_RECIP_DEVICE,
		.bRequest = USB_REQ_GET_DESCRIPTOR,
		.wValue = (uint16_t)((type_idx << 8) | index),
		.wIndex = 0,
		.wLength = len,
		.timeout = IO_TIMEOUT_MS,
		.data = data,
	};
	return ioctl(fd, USBDEVFS_CONTROL, &c) == (int)len ? 0 : -1;
}

static int identify_bridge(int fd)
{
	uint8_t d[18];
	uint16_t vid, pid;

	if (get_descriptor(fd, USB_DT_DEVICE, 0, d, sizeof(d)) < 0)
		return -1;
	vid = (uint16_t)(d[8] | (d[9] << 8));
	pid = (uint16_t)(d[10] | (d[11] << 8));
	return (vid == BRIDGE_VID && pid == BRIDGE_PID) ? 0 : -1;
}

static void commit_interface(struct kbdev *kb, int cur_if, int cur_class,
			     int cur_proto, uint8_t cur_in, uint8_t cur_out)
{
	if (cur_class == 3 && cur_proto == 1 && kb->kbd_if < 0)
		kb->kbd_if = cur_if;
	else if (cur_class == 3 && cur_proto == 2 && kb->mouse_if < 0)
		kb->mouse_if = cur_if;
	if (cur_in && cur_out && kb->cmd_if < 0) {
		kb->cmd_if = cur_if;
		kb->in_ep = cur_in;
		kb->out_ep = cur_out;
	}
}

static int parse_config(int fd, struct kbdev *kb)
{
	uint8_t head[9], buf[256];
	uint16_t total;
	int pos = 0;
	int cur_if = -1, cur_class = -1, cur_proto = -1;
	uint8_t cur_in = 0, cur_out = 0;

	kb->kbd_if = -1;
	kb->mouse_if = -1;
	kb->cmd_if = -1;
	kb->in_ep = 0;
	kb->out_ep = 0;

	if (get_descriptor(fd, USB_DT_CONFIG, 0, head, sizeof(head)) < 0)
		return -1;
	total = (uint16_t)(head[2] | (head[3] << 8));
	if (total < sizeof(head) || total > sizeof(buf))
		return -1;
	if (get_descriptor(fd, USB_DT_CONFIG, 0, buf, total) < 0)
		return -1;

	while (pos + 2 <= total) {
		uint8_t len = buf[pos];
		uint8_t type = buf[pos + 1];

		if (len < 2 || pos + len > total)
			break;
		if (type == USB_DT_INTERFACE) {
			commit_interface(kb, cur_if, cur_class, cur_proto,
					 cur_in, cur_out);
			cur_if = buf[pos + 2];
			cur_class = buf[pos + 5];
			cur_proto = buf[pos + 7];
			cur_in = 0;
			cur_out = 0;
		} else if (type == USB_DT_ENDPOINT) {
			uint8_t addr = buf[pos + 2];

			if (addr & USB_DIR_IN) {
				if (!cur_in)
					cur_in = addr;
			} else {
				if (!cur_out)
					cur_out = addr;
			}
		}
		pos += len;
	}
	commit_interface(kb, cur_if, cur_class, cur_proto, cur_in, cur_out);

	if (kb->cmd_if < 0) {
		LOGW("no IN+OUT command interface");
		return -1;
	}
	return 0;
}

static int if_ioctl(int fd, int ifn, unsigned int code)
{
	struct usbdevfs_ioctl io = {
		.ifno = ifn,
		.ioctl_code = (int)code,
		.data = NULL,
	};
	return ioctl(fd, USBDEVFS_IOCTL, &io);
}

static int open_bridge(struct kbdev *kb, enum attach cur)
{
	DIR *bd, *dd;
	struct dirent *be, *de;

	kb->fd = -1;

	bd = opendir(USBDEVFS_PATH);
	if (!bd)
		return -1;
	while ((be = readdir(bd))) {
		char busdir[64];

		if (be->d_name[0] == '.')
			continue;
		snprintf(busdir, sizeof(busdir), USBDEVFS_PATH "/%s",
			 be->d_name);
		dd = opendir(busdir);
		if (!dd)
			continue;
		while ((de = readdir(dd))) {
			int fd;
			unsigned int ifn;

			if (de->d_name[0] == '.')
				continue;
			snprintf(kb->path, sizeof(kb->path), "%s/%s", busdir,
				 de->d_name);
			fd = open(kb->path, O_RDWR);
			if (fd < 0)
				continue;
			if (identify_bridge(fd) < 0) {
				close(fd);
				continue;
			}
			if (parse_config(fd, kb) < 0) {
				close(fd);
				continue;
			}

			if (cur == ATTACH_DETACHED) {
				if (kb->kbd_if >= 0)
					if_ioctl(fd, kb->kbd_if, USBDEVFS_DISCONNECT);
				if (kb->mouse_if >= 0)
					if_ioctl(fd, kb->mouse_if, USBDEVFS_DISCONNECT);
			} else if (cur == ATTACH_ATTACHED) {
				if (kb->kbd_if >= 0)
					if_ioctl(fd, kb->kbd_if, USBDEVFS_CONNECT);
				if (kb->mouse_if >= 0)
					if_ioctl(fd, kb->mouse_if, USBDEVFS_CONNECT);
			}

			if_ioctl(fd, kb->cmd_if, USBDEVFS_DISCONNECT);
			ifn = (unsigned int)kb->cmd_if;
			if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifn) < 0) {
				LOGE("claim if%d failed: %s", kb->cmd_if,
				     strerror(errno));
				close(fd);
				continue;
			}
			kb->fd = fd;
			LOGI("claimed %s if%d (cmd eps out 0x%02x in 0x%02x, "
			     "kbd if%d, mouse if%d)",
			     kb->path, kb->cmd_if, kb->out_ep, kb->in_ep,
			     kb->kbd_if, kb->mouse_if);
			closedir(bd);
			closedir(dd);
			return 0;
		}
		closedir(dd);
	}
	closedir(bd);
	return -1;
}

static int query_connect(struct kbdev *kb, enum attach *out)
{
	static int dump_count;
	struct usbdevfs_bulktransfer bt;
	uint8_t resp[64];
	int n, i;

	memset(&bt, 0, sizeof(bt));
	bt.ep = kb->out_ep;
	bt.len = sizeof(kGetConnectState);
	bt.timeout = IO_TIMEOUT_MS;
	bt.data = (void *)kGetConnectState;
	if (ioctl(kb->fd, USBDEVFS_BULK, &bt) != (int)sizeof(kGetConnectState)) {
		LOGW("bulk out failed: %s", strerror(errno));
		return -2;
	}

	memset(&bt, 0, sizeof(bt));
	bt.ep = kb->in_ep;
	bt.len = sizeof(resp);
	bt.timeout = IO_TIMEOUT_MS;
	bt.data = resp;
	n = ioctl(kb->fd, USBDEVFS_BULK, &bt);
	if (n < 0) {
		LOGW("bulk in failed: %s", strerror(errno));
		return -2;
	}

	if (dump_count < 3) {
		char hex[3 * 64 + 1];

		hex[0] = '\0';
		for (i = 0; i < n && i < (int)sizeof(resp); i++)
			sprintf(hex + strlen(hex), "%02x ", resp[i]);
		LOGI("rsp[%d]: %s", n, hex);
		dump_count++;
	}

	if (n < 19 || resp[4] != 0xA2) {
		LOGW("invalid response (%d bytes, [4]=0x%02x)", n,
		     n > 4 ? resp[4] : 0);
		return -1;
	}
	if (resp[18] == 1) {
		LOGW("keyboard over charged, holding state");
		return 0;
	}
	if ((resp[9] & 0x03) == 1) {
		LOGW("TRX check failed (st=0x%02x), holding state", resp[9]);
		return 0;
	}
	if ((resp[9] & 0x63) == 0x43) {
		LOGW("pogo pin fault (st=0x%02x), holding state", resp[9]);
		return 0;
	}
	if ((resp[9] & 0x03) == 0) {
		*out = ATTACH_DETACHED;
		return 1;
	}
	if ((resp[9] & 0x63) == 0x23) {
		*out = ATTACH_ATTACHED;
		return 1;
	}
	LOGW("unhandled connect state 0x%02x, holding", resp[9]);
	return 0;
}

static void apply_gate(const struct kbdev *kb, enum attach st)
{
	int ifs[2] = { kb->kbd_if, kb->mouse_if };
	unsigned int code = (st == ATTACH_ATTACHED) ?
				    USBDEVFS_CONNECT :
				    USBDEVFS_DISCONNECT;
	int i;

	if (st == ATTACH_UNKNOWN)
		return;
	for (i = 0; i < 2; i++) {
		if (ifs[i] < 0)
			continue;
		if_ioctl(kb->fd, ifs[i], code);
	}
}

int main(void)
{
	struct kbdev kb;
	enum attach cur = ATTACH_UNKNOWN;
	int fails = 0;
	int fast_ms = 0;

	memset(&kb, 0, sizeof(kb));
	kb.fd = -1;
	signal(SIGPIPE, SIG_IGN);

	LOGI("started (bridge powered, gating input interfaces)");

	for (;;) {
		enum attach st = ATTACH_UNKNOWN;
		int r;

		if (kb.fd < 0) {
			if (open_bridge(&kb, cur) < 0) {
				if (fast_ms > 0) {
					msleep(FAST_WAIT_MS);
					fast_ms -= FAST_WAIT_MS;
				} else {
					msleep(WAIT_MS);
				}
				continue;
			}

			if (cur != ATTACH_UNKNOWN) {
				int i;

				for (i = 0; i < 5; i++) {
					apply_gate(&kb, cur);
					msleep(100);
				}
			}
			fails = 0;
		}

		r = query_connect(&kb, &st);
		if (r == -2) {
			close(kb.fd);
			kb.fd = -1;
			fails = 0;
			fast_ms = FAST_WINDOW_MS;
			msleep(FAST_WAIT_MS);
			fast_ms -= FAST_WAIT_MS;
			if (fast_ms < 0)
				fast_ms = 0;
			continue;
		}
		if (r < 0) {
			if (++fails >= 3) {
				LOGE("repeated invalid responses, reopening");
				close(kb.fd);
				kb.fd = -1;
				fails = 0;
				fast_ms = FAST_WINDOW_MS;
			}
			msleep(POLL_MS);
			continue;
		}
		fails = 0;
		fast_ms = 0;
		if (r > 0 && st != cur) {
			LOGI("keyboard case %s",
			     st == ATTACH_ATTACHED ? "ATTACHED" : "DETACHED");
			cur = st;
		}
		apply_gate(&kb, cur);
		msleep(POLL_MS);
	}

	return 0;
}
