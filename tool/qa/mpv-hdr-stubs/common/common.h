#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
void *memcpy(void *, const void *, size_t);
void *memset(void *, int, size_t);
int memcmp(const void *, const void *, size_t);
void *fixture_talloc_zero(size_t);
void talloc_free(void *);
#define talloc_zero(parent, type) ((type *)fixture_talloc_zero(sizeof(type)))
