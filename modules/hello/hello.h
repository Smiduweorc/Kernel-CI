/* SPDX-License-Identifier: GPL-2.0 */
#ifndef HELLO_H
#define HELLO_H

#define HELLO_REPEAT_MAX 16
#define HELLO_NAME_MAX 32

int hello_parse_repeat(const char *val, unsigned int *repeat);
int hello_check_name(const char *name);

#endif
