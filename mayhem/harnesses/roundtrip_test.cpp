/*
 * grok/mayhem/harnesses/roundtrip_test.cpp — self-contained known-answer test for grok's core
 * JPEG 2000 decoder, used by mayhem/test.sh as the PATCH-grade oracle.
 *
 * It decodes two small, bundled golden images (mayhem/testdata/) through grok's real decode path
 * (grk_decompress_init -> grk_decompress_read_header -> grk_decompress) and asserts EXACT, known
 * answers extracted from each file's JPEG 2000 SIZ marker:
 *
 *   basn4a08.jp2  — JP2 (box format):  32 x 32, 2 components, 8-bit  (PNG-derived, grayscale+alpha)
 *   p0_12.j2k     — raw J2K codestream: 3 x 5,  1 component, 8-bit   (ISO conformance file p0_12)
 *
 * For each file the test asserts the decoded image width / height / component count / precision
 * equal the hard-coded expected values AND that full grk_decompress() succeeds. A no-op / exit(0) /
 * "always return success without parsing" patch cannot produce the correct dimensions, so it fails.
 *
 * Paths to the golden files are passed as argv (mayhem/test.sh supplies them). Exit 0 iff every
 * assertion holds.
 */
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include "grok.h"

struct Expect
{
  const char* name;
  uint32_t w, h;
  uint16_t numcomps;
  uint8_t prec;
};

static int fail(const char* file, const char* msg)
{
  fprintf(stderr, "roundtrip_test FAIL [%s]: %s\n", file, msg);
  return 1;
}

static int check_one(const char* path, const Expect& e)
{
  FILE* f = fopen(path, "rb");
  if(!f)
    return fail(e.name, "cannot open golden file");
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if(n <= 0)
  {
    fclose(f);
    return fail(e.name, "empty golden file");
  }
  std::vector<uint8_t> buf((size_t)n);
  if(fread(buf.data(), 1, (size_t)n, f) != (size_t)n)
  {
    fclose(f);
    return fail(e.name, "short read");
  }
  fclose(f);

  grk_header_info hdr = {};
  grk_decompress_parameters dp = {};
  dp.dw_x1 = 1u << 20; // generous decode window so full image decodes
  dp.dw_y1 = 1u << 20;
  grk_stream_params sp = {};
  sp.buf = buf.data();
  sp.buf_len = (size_t)n;

  grk_object* dec = grk_decompress_init(&sp, &dp);
  if(!dec)
    return fail(e.name, "grk_decompress_init returned null");
  if(!grk_decompress_read_header(dec, &hdr))
  {
    grk_object_unref(dec);
    return fail(e.name, "grk_decompress_read_header failed");
  }

  grk_image* hi = &hdr.header_image;
  uint32_t w = hi->x1 - hi->x0;
  uint32_t h = hi->y1 - hi->y0;
  if(w != e.w || h != e.h)
  {
    fprintf(stderr, "  got %ux%u expected %ux%u\n", w, h, e.w, e.h);
    grk_object_unref(dec);
    return fail(e.name, "dimension mismatch");
  }
  if(hi->numcomps != e.numcomps)
  {
    fprintf(stderr, "  got numcomps=%u expected %u\n", hi->numcomps, e.numcomps);
    grk_object_unref(dec);
    return fail(e.name, "component count mismatch");
  }
  if(!hi->comps || hi->comps[0].prec != e.prec)
  {
    grk_object_unref(dec);
    return fail(e.name, "precision mismatch");
  }

  if(!grk_decompress(dec, nullptr))
  {
    grk_object_unref(dec);
    return fail(e.name, "grk_decompress failed");
  }

  grk_object_unref(dec);
  printf("roundtrip_test PASS [%s]: %ux%u x%u prec%u\n", e.name, w, h, (unsigned)e.numcomps,
         (unsigned)e.prec);
  return 0;
}

int main(int argc, char** argv)
{
  if(argc < 3)
  {
    fprintf(stderr, "usage: %s <basn4a08.jp2> <p0_12.j2k>\n", argv[0]);
    return 2;
  }
  grk_initialize(nullptr, 0, nullptr);

  const Expect e_jp2 = {"basn4a08.jp2", 32, 32, 2, 8};
  const Expect e_j2k = {"p0_12.j2k", 3, 5, 1, 8};

  int rc = 0;
  rc |= check_one(argv[1], e_jp2);
  rc |= check_one(argv[2], e_j2k);
  if(rc == 0)
    printf("roundtrip_test PASS: all golden decodes matched known answers\n");
  return rc;
}
