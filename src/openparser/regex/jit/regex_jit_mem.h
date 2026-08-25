#ifndef VC_JIT_MEM_H
#define VC_JIT_MEM_H

#include <sys/mman.h>
#include <stdlib.h>

static inline void* vc_alloc_jit_code(size_t size) {
  void* p = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  return (p == MAP_FAILED) ? NULL : p;
}

static inline void vc_free_jit_code(void* p, size_t size) {
  munmap(p, size);
}

#endif
