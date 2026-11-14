# MYSTRAN patch: the upstream Reference-LAPACK CMake refuses to be built
# when CMAKE_BINARY_DIR == CMAKE_SOURCE_DIR. MYSTRAN's own configuration
# is an in-source build by design (see CMakeLists.txt), so the embedded
# LAPACK sub-build fails that check even though its actual binary dir
# (under ${PROJECT_BINARY_DIR}/lapack) is disjoint from its source tree.
#
# This stub replaces the upstream guard with a no-op so the embedded
# build can proceed.
function(AssureOutOfSourceBuilds)
endfunction()

AssureOutOfSourceBuilds()
