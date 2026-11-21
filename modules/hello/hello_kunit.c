// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include <linux/module.h>
#include <linux/string.h>
#include <linux/version.h>

#include "hello.h"

/* No valid repeat is this large, so seeing it means nothing was written. */
#define UNTOUCHED 99U

struct repeat_case {
	const char *desc;
	const char *input;
	int err;
	unsigned int value;
};

static const struct repeat_case repeat_cases[] = {
	{ "one is the minimum", "1", 0, 1 },
	{ "sixteen is the maximum", "16", 0, 16 },
	{ "zero is one under", "0", -ERANGE, 0 },
	{ "seventeen is one over", "17", -ERANGE, 0 },
	{ "UINT_MAX is out of range", "4294967295", -ERANGE, 0 },
	{ "past UINT_MAX overflows", "4294967296", -ERANGE, 0 },
	{ "one trailing newline from sysfs is accepted", "3\n", 0, 3 },
	{ "two trailing newlines are not", "3\n\n", -EINVAL, 0 },
	{ "a leading plus is accepted", "+3", 0, 3 },
	{ "a leading zero is still decimal", "08", 0, 8 },
	{ "empty", "", -EINVAL, 0 },
	{ "negative", "-1", -EINVAL, 0 },
	{ "leading space", " 3", -EINVAL, 0 },
	{ "hex prefix", "0x3", -EINVAL, 0 },
	{ "trailing garbage", "3a", -EINVAL, 0 },
};

static void repeat_case_desc(const struct repeat_case *c, char *desc)
{
	strscpy(desc, c->desc, KUNIT_PARAM_DESC_SIZE);
}

KUNIT_ARRAY_PARAM(repeat, repeat_cases, repeat_case_desc);

static void parse_repeat_test(struct kunit *test)
{
	const struct repeat_case *c = test->param_value;
	unsigned int value = UNTOUCHED;

	KUNIT_EXPECT_EQ(test, hello_parse_repeat(c->input, &value), c->err);
	KUNIT_EXPECT_EQ(test, value, c->err ? UNTOUCHED : c->value);
}

struct name_case {
	const char *desc;
	const char *input;
	int err;
};

static const struct name_case name_cases[] = {
	{ "a plain name", "world", 0 },
	{ "one byte is the minimum", "a", 0 },
	{ "empty", "", -EINVAL },
	{ "32 bytes is the maximum", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0 },
	{ "33 bytes is one over", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", -EINVAL },
	/* The limit is in bytes: 16 two-byte characters fill it exactly. */
	{ "32 bytes of UTF-8",
	  "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9"
	  "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9", 0 },
	{ "33 bytes of UTF-8",
	  "a\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9"
	  "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9", -EINVAL },
};

static void name_case_desc(const struct name_case *c, char *desc)
{
	strscpy(desc, c->desc, KUNIT_PARAM_DESC_SIZE);
}

KUNIT_ARRAY_PARAM(name, name_cases, name_case_desc);

static void check_name_test(struct kunit *test)
{
	const struct name_case *c = test->param_value;

	KUNIT_EXPECT_EQ(test, hello_check_name(c->input), c->err);
}

static struct kunit_case hello_test_cases[] = {
	KUNIT_CASE_PARAM(parse_repeat_test, repeat_gen_params),
	KUNIT_CASE_PARAM(check_name_test, name_gen_params),
	{}
};

static struct kunit_suite hello_test_suite = {
	.name = "hello",
	.test_cases = hello_test_cases,
};

kunit_test_suite(hello_test_suite);

/* 6.13 turned symbol namespaces from bare identifiers into strings. */
#if KERNEL_VERSION(6, 13, 0) <= LINUX_VERSION_CODE
MODULE_IMPORT_NS("EXPORTED_FOR_KUNIT_TESTING");
#else
MODULE_IMPORT_NS(EXPORTED_FOR_KUNIT_TESTING);
#endif
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("KUnit tests for hello");
