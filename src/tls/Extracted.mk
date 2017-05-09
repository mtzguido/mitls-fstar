include Makefile

mlclean:
	$(MAKE) -C $(FSTAR_HOME)/ulib/ml clean MEM=HST
	$(MAKE) -C $(FSTAR_HOME)/ucontrib/CoreCrypto/ml clean
	$(MAKE) -C $(FSTAR_HOME)/ucontrib/Platform/ml clean
	$(MAKE) -C $(HACL_HOME)/secure_api/LowCProvider clean
	$(MAKE) -C $(FFI_HOME) clean
	-rm -rf test/*.cm* test/*.o
	-rm -fr $(ODIR)/*.cm* $(ODIR)/*.o $(ODIR)/.tmp $(ODIR)/.deporder *.exe *.cm* *.o *.so *.dll *.out

.PHONY: mlclean

# Makefile voodoo to substitute _ for . in module names
# Note that this is not sound if the F* module name contains an underscore (e.g. AEAD_GCM.fst)
# The dependencies are handled by the .depend files above to allow semi-incremental extraction
# (it is only incremental on connected components of the dependency graph rather than on a per-module basis)
.SECONDEXPANSION:
$(ODIR)/%.ml: $$(subst _,.,%.fst)
	$(FSTAR) $(FSTAR_INCLUDE_PATHS) --lax --codegen OCaml \
	--odir $(ODIR) $(NOEXTRACT) \
	$(addprefix --codegen-lib , $(CODEGEN_LIBS)) \
	--include concrete-flags $<

$(ODIR)/Test%.ml: test/Test%.fst
	$(FSTAR) $(FSTAR_INCLUDE_PATHS) --lax --codegen OCaml \
	--odir $(ODIR) $(NOEXTRACT) \
	$(addprefix --codegen-lib , $(CODEGEN_LIBS)) \
	--include concrete-flags --extract_module Test$(*F) $<

# Special case for Crypto.AEAD.*: must look in hacl-star/secure_api/aead
# Note that dependencies have absolute paths in the .depend so there is no need 
# to specialize for other internal Hacl paths
$(ODIR)/Crypto_AEAD_%.ml: $(LLDIR)/aead/Crypto.AEAD.%.fst
	$(FSTAR) $(FSTAR_INCLUDE_PATHS) --lax --codegen OCaml \
	--odir $(ODIR) $(NOEXTRACT) \
	$(addprefix --codegen-lib , $(CODEGEN_LIBS)) \
	--include concrete-flags $<

# Hacl flags: extract with concrete
$(ODIR)/Flag.ml: $(LLDIR)/test/Flag.fst
	$(FSTAR) $(FSTAR_INCLUDE_PATHS) --lax --codegen OCaml \
	--odir $(ODIR) $(NOEXTRACT) \
	$(addprefix --codegen-lib , $(CODEGEN_LIBS)) \
	--include concrete-flags $<

# Try to only rebuild fstarlib when necessary
$(FSTAR_HOME)/ulib/ml/fstarlib.cmxa: \
       		$(wildcard $(FSTAR_HOME)/ulib/*.fst) \
		$(wildcard $(FSTAR_HOME)/ulib/ml/*.ml) \
	       	$(wildcard $(FSTAR_HOME)/ulib/ml/extracted/*.ml) \
		$(wildcard $(FSTAR_HOME)/ulib/ml/hyperstack/*.ml)
	make -C $(FSTAR_HOME)/ulib/ml MEM=HST

# Try to only rebuild CoreCrypto when necessary
$(FSTAR_HOME)/ucontrib/CoreCrypto/ml/CoreCrypto.cmi $(FSTAR_HOME)/ucontrib/CoreCrypto/ml/CoreCrypto.cmx $(FSTAR_HOME)/ucontrib/CoreCrypto/ml/CoreCrypto.cmxa: \
		$(FSTAR_HOME)/ucontrib/CoreCrypto/ml/CoreCrypto.ml
	make -C $(FSTAR_HOME)/ucontrib/CoreCrypto/ml

# Try to only rebuild LowCProvider when necessary
# Missing: not dependency on hacl-star/code/*
$(LCDIR)/LowCProvider.cmxa: $(FSTAR_HOME)/ucontrib/CoreCrypto/ml/CoreCrypto.cmxa $(wildcard $(LLDIR)/*/*.fst)
	make -C $(LCDIR)

$(FFI_HOME)/FFICallbacks.cmxa: $(wildcard $(FFI_HOME)/*.ml) $(wildcard $(FFI_HOME)/*.c)
	make -C $(FFI_HOME)

%.cmi %.cmx: %.ml
	ocamlfind ocamlopt $(OCAMLOPTS) $(OCAML_INCLUDE_PATHS) -c $<
	@[ -f $(ODIR)/.deporder ] || echo -n "$(subst .ml,.cmx,$<) " >> $(ODIR)/.tmp

.depend-ML: \
	$(ODIR)/Flag.ml \
	$(ODIR)/CommonDH.ml \
	$(ODIR)/Crypto_AEAD_Main.ml \
	$(ODIR)/HandshakeLog.ml \
	$(ODIR)/Handshake.ml \
	$(ODIR)/FFI.ml \
	$(ODIR)/TestAPI.ml \
	$(ODIR)/TestFFI.ml
	ocamlfind ocamldep -native -slash -all $(OCAMLPKG) $(OCAML_INCLUDE_PATHS) $(addsuffix /*.ml,$(OCAML_PATHS)) > .depend-ML

-include .depend-ML

$(ODIR)/.deporder: $(ODIR)/FFI.cmx $(ODIR)/TestAPI.cmx $(ODIR)/TestFFI.cmx
	@echo "=== Note: ML dependencies may be outdated. If you have a link-time error, run `make mlclean` ==="
	@cp $(ODIR)/.tmp $(ODIR)/.deporder

mitls.cmxa: \
	$(FSTAR_HOME)/ulib/ml/fstarlib.cmxa \
       	$(FSTAR_HOME)/ucontrib/CoreCrypto/ml/CoreCrypto.cmxa \
       	$(LCDIR)/LowCProvider.cmxa \
	$(FFI_HOME)/FFICallbacks.cmxa \
	$(ODIR)/.deporder $(ODIR)/FFI.cmx
	ocamlfind ocamlopt $(OCAML_INCLUDE_PATHS) -a `cat $(ODIR)/.deporder` -o mitls.cmxa

mitls.exe: mitls.cmxa test/mitls.cmx
	ocamlfind ocamlopt $(OCAMLOPTS) $(OCAML_INCLUDE_PATHS) -I test/ -g \
	$(FSTAR_HOME)/ulib/ml/fstarlib.cmxa \
	$(FSTAR_HOME)/ucontrib/CoreCrypto/ml/CoreCrypto.cmxa \
	$(LCDIR)/lowc_stub.o $(LCDIR)/libllcrypto.a $(LCDIR)/LowCProvider.cmx \
	$(FFI_HOME)/FFICallbacks.cmxa \
	mitls.cmxa test/mitls.cmx -o mitls.exe

test.out: mitls.cmxa $(ODIR)/TestKS.ml $(ODIR)/TestDH.ml $(ODIR)/TestGCM.ml test/parsing_test.ml test/test_hkdf.ml test/test_main.ml
	ocamlfind ocamlopt $(OCAMLOPTS) $(OCAML_INCLUDE_PATHS) \
	$(FSTAR_HOME)/ulib/ml/fstarlib.cmxa \
	$(FSTAR_HOME)/ucontrib/CoreCrypto/ml/CoreCrypto.cmxa \
	$(LCDIR)/lowc_stub.o $(LCDIR)/libllcrypto.a $(LCDIR)/LowCProvider.cmx \
	mitls.cmxa \
	$(ODIR)/TestKS.ml $(ODIR)/TestDH.ml $(ODIR)/TestGCM.ml test/parsing_test.ml test/test_hkdf.ml test/test_main.ml -o test.out

test: test.out mitls.exe
	# Unit tests from test/test_main.ml
	$(EXTRA_PATH) ./test.out
	# Run mitls.exe 
	./mitls.exe  -v 1.2 -ffi www.google.com
	./mitls.exe  -v 1.2 -noems www.microsoft.com
	#./mitls.exe -v 1.3. www.google.com failing due to different draft versions

# FFI support - calling from C into miTLS. TODO: remove duplication somehow
ifeq ($(OS),Windows_NT)
tls-ffi: mitls.cmxa
	$(OCAML) $(OCAMLOPTS) $(OCAML_INCLUDE_PATHS) $(LIB_ML) -linkall -output-obj -g mitls.cmxa -o libmitls.dll
else
UNAME_S = $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
tls-ffi: mitls.cmxa
	$(OCAML) $(OCAMLOPTS) $(OCAML_INCLUDE_PATHS) $(LIB_ML) -linkall -runtime-variant _pic -ccopt -dynamiclib -ccopt -lasmrun -g mitls.cmxa -o libmitls.dylib
	$(OCAML) $(OCAMLOPTS) $(OCAML_INCLUDE_PATHS) $(LIB_ML) -linkall -runtime-variant _pic -output-obj -ccopt -bundle -g mitls.cmxa -o libmitls.so
else
tls-ffi: mitls.cmxa
	$(OCAML) $(OCAMLOPTS) $(OCAML_INCLUDE_PATHS) $(LIB_ML) -linkall -runtime-variant _pic -output-obj -g mitls.cmxa -o libmitls.so
endif
endif

# our interactive tests; the baseline is make client{|12|13} vs make server 

server::
	OCAMLRUNPARAM=b ./mitls.exe -mv 1.2 -v 1.3 -s -cert ../../data/server.crt -key ../../data/server.key 127.0.0.1 4443 
server12::
	OCAMLRUNPARAM=b ./mitls.exe -mv 1.2 -v 1.2 -s -cert ../../data/server.crt -key ../../data/server.key 127.0.0.1 4443 
server13::
	OCAMLRUNPARAM=b ./mitls.exe -mv 1.3 -v 1.3 -s -cert ../../data/server.crt -key ../../data/server.key 127.0.0.1 4443 

client13::
	OCAMLRUNPARAM=b ./mitls.exe -mv 1.3 -v 1.3 127.0.0.1 4443 
client12::
	OCAMLRUNPARAM=b ./mitls.exe -mv 1.2 -v 1.2 127.0.0.1 4443 
client::
	OCAMLRUNPARAM=b ./mitls.exe -mv 1.2 -v 1.3 127.0.0.1 4443

.PHONY: test tls-ffi server server12 server13 client client12 client13

.DEFAULT:

