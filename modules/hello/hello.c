// SPDX-License-Identifier: GPL-2.0
#include <kunit/visibility.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/string.h>

#include "hello.h"

static unsigned int hello_repeat = 1;
static char *hello_name = "world";

/*
 * Leaves *repeat untouched on failure, so a rejected value never replaces the
 * one already loaded.
 */
int hello_parse_repeat(const char *val, unsigned int *repeat)
{
	unsigned int n;
	int err;

	err = kstrtouint(val, 10, &n);
	if (err)
		return err;
	if (n < 1 || n > HELLO_REPEAT_MAX)
		return -ERANGE;
	*repeat = n;
	return 0;
}
EXPORT_SYMBOL_IF_KUNIT(hello_parse_repeat);

int hello_check_name(const char *name)
{
	size_t len = strnlen(name, HELLO_NAME_MAX + 1);

	if (len == 0 || len > HELLO_NAME_MAX)
		return -EINVAL;
	return 0;
}
EXPORT_SYMBOL_IF_KUNIT(hello_check_name);

static int repeat_set(const char *val, const struct kernel_param *kp)
{
	return hello_parse_repeat(val, kp->arg);
}

static int name_set(const char *val, const struct kernel_param *kp)
{
	int err = hello_check_name(val);

	if (err)
		return err;
	return param_set_charp(val, kp);
}

static const struct kernel_param_ops repeat_ops = {
	.set = repeat_set,
	.get = param_get_uint,
};

static const struct kernel_param_ops name_ops = {
	.set = name_set,
	.get = param_get_charp,
	.free = param_free_charp,
};

/*
 * Read-only in sysfs: hello_show reads both without kernel_param_lock, which
 * is only safe while nothing can change them after load.
 */
module_param_cb(repeat, &repeat_ops, &hello_repeat, 0444);
MODULE_PARM_DESC(repeat, "Lines in /proc/hello, 1 to 16 (default 1)");
module_param_cb(name, &name_ops, &hello_name, 0444);
MODULE_PARM_DESC(name, "Who /proc/hello greets, 1 to 32 bytes (default world)");

static int hello_show(struct seq_file *m, void *v)
{
	unsigned int i;

	for (i = 0; i < hello_repeat; i++)
		seq_printf(m, "hello, %s\n", hello_name);
	return 0;
}

static int __init hello_init(void)
{
	if (!proc_create_single("hello", 0444, NULL, hello_show))
		return -ENOMEM;
	return 0;
}

static void __exit hello_exit(void)
{
	remove_proc_entry("hello", NULL);
}

module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Greets from /proc/hello");
