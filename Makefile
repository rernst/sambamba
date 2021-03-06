D_COMPILER=dmd
D_FLAGS=-IBioD -g#-O -release -inline # -version=serial

STATIC_LIB_PATH=-Lhtslib -Llz4/lib
STATIC_LIB_SUBCMD=$(STATIC_LIB_PATH) -Wl,-Bstatic -lhts -llz4 -Wl,-Bdynamic
RDMD_FLAGS=--force --build-only --compiler=$(D_COMPILER) $(D_FLAGS)

# Linux & DMD only - this goal is used because of fast compilation speed, during development
all: htslib-static lz4-static
	mkdir -p build/
	rdmd --force --build-only $(D_FLAGS) -L-Lhtslib -L-l:libhts.a -L-l:libphobos2.a -ofbuild/sambamba main.d

PLATFORM := $(shell uname -s)

ifeq "$(PLATFORM)" "Darwin"
LINK_CMD=gcc -dead_strip -lphobos2-ldc -ldruntime-ldc -lm -lpthread htslib/libhts.a lz4/lib/liblz4.a build/sambamba.o -o build/sambamba
else
LINK_CMD=gcc -Wl,--gc-sections -o build/sambamba build/sambamba.o $(STATIC_LIB_SUBCMD) -l:libphobos2-ldc.a -l:libdruntime-ldc.a  -lrt -lpthread -lm
endif

# This is the main Makefile goal, used for building releases (best performance)
sambamba-ldmd2-64: htslib-static lz4-static
	mkdir -p build/
	ldmd2 @sambamba-ldmd-release.rsp
	$(LINK_CMD)

# For debugging; GDB & Valgrind are more friendly to executables created using LDC/GDC than DMD
sambamba-ldmd2-debug: htslib-static lz4-static
	mkdir -p build/
	ldmd2 @sambamba-ldmd-debug.rsp
	$(LINK_CMD)

htslib-static:
	cd htslib && $(MAKE)

lz4-static:
	cd lz4/lib && $(MAKE)

# all below link to libhts dynamically for simplicity

sambamba-flagstat:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-flagstat sambamba/flagstat.d

sambamba-merge:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-merge sambamba/merge.d

sambamba-index:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-index sambamba/index.d

sambamba-sort:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-sort sambamba/sort.d

sambamba-view:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-view sambamba/view.d

sambamba-slice:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-slice sambamba/slice.d

sambamba-markdup:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-markdup sambamba/markdup.d

sambamba-depth:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-depth sambamba/depth.d

sambamba-pileup:
	mkdir -p build/
	rdmd $(RDMD_FLAGS) -L-lhts -version=standalone -ofbuild/sambamba-pileup sambamba/pileup.d

.PHONY: clean

clean:
	rm -rf build/ ; cd htslib ; make clean
