#ifndef VC_JIT_MEM_H
#define VC_JIT_MEM_H

#include <stdlib.h>

#ifdef _WIN32
#include <windows.h>

static inline void* vc_alloc_jit_code(size_t size) {
  return VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
}

static inline void vc_free_jit_code(void* p, size_t size) {
  (void)size;
  VirtualFree(p, 0, MEM_RELEASE);
}

#else
#include <sys/mman.h>

static inline void* vc_alloc_jit_code(size_t size) {
  void* p = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  return (p == MAP_FAILED) ? NULL : p;
}

static inline void vc_free_jit_code(void* p, size_t size) {
  munmap(p, size);
}

#endif

#endif
