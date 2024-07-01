cmake -S . -B build -DCMAKE_INSTALL_PREFIX=install -DCMAKE_Fortran_COMPILER=gfortran
cmake --build build --target install
cpp -traditional fortran/common/consts.F90 -o consts_preprocessed.F90
lfortran consts_preprocessed.F90 -c
lfortran fortran/common/infos.f90 -c
cpp -traditional fortran/common/debug.F90 -o debug_preprocessed.F90
lfortran debug_preprocessed.F90 -c
cpp -traditional fortran/common/huge.F90 -o huge_preprocessed.F90
lfortran huge_preprocessed.F90 -c
cpp -traditional fortran/common/inf.F90 -o inf_preprocessed.F90
lfortran inf_preprocessed.F90 -c
cpp -traditional fortran/common/infnan.F90 -o infnan_preprocessed.F90
lfortran infnan_preprocessed.F90 -c
lfortran fortran/common/checkexit.f90 -c
cpp -traditional fortran/common/memory.F90 -o memory_preprocessed.F90
lfortran memory_preprocessed.F90 -c 
lfortran fortran/common/string.f90 -c 
lfortran fortran/common/linalg.f90 -c
lfortran fortran/common/pintrf.f90 -c
lfortran fortran/common/evaluate.f90 -c
lfortran fortran/common/powalg.f90 -c
lfortran fortran/bobyqa/geometry.f90 -c
lfortran fortran/common/history.f90 -c
lfortran fortran/common/fprint.f90 -c
lfortran fortran/common/message.f90 -c
lfortran fortran/common/xinbd.f90 -c
lfortran fortran/bobyqa/initialize.f90 -c
lfortran fortran/common/ratio.f90 -c
lfortran fortran/common/redrho.f90 -c
lfortran fortran/bobyqa/rescue.f90 -c
lfortran fortran/common/shiftbase.f90 -c
lfortran fortran/common/univar.f90 -c
lfortran fortran/bobyqa/trustregion.f90 -c
lfortran fortran/bobyqa/update.f90 -c
lfortran fortran/bobyqa/bobyqb.f90 -c
lfortran fortran/common/preproc.f90 -c
lfortran fortran/bobyqa/bobyqa.f90 -c
lfortran fortran/cobyla/geometry.f90 -c
lfortran fortran/common/selectx.f90 -c
lfortran fortran/cobyla/initialize.f90 -c
lfortran fortran/cobyla/trustregion.f90 -c
lfortran fortran/cobyla/update.f90 -c
lfortran fortran/cobyla/cobylb.f90 -c
lfortran fortran/cobyla/cobyla.f90 -c
lfortran fortran/lincoa/geometry.f90 -c
lfortran fortran/lincoa/getact.f90 -c
lfortran fortran/lincoa/initialize.f90 -c
lfortran fortran/lincoa/trustregion.f90 -c
lfortran fortran/lincoa/update.f90 -c
lfortran fortran/lincoa/lincob.f90 -c
lfortran fortran/lincoa/lincoa.f90 -c
lfortran fortran/newuoa/geometry.f90 -c
lfortran fortran/newuoa/initialize.f90 -c
lfortran fortran/newuoa/trustregion.f90 -c
lfortran fortran/newuoa/update.f90 -c
lfortran fortran/newuoa/newuob.f90 -c
lfortran fortran/newuoa/newuoa.f90 -c
lfortran fortran/uobyqa/geometry.f90 -c
lfortran fortran/uobyqa/initialize.f90 -c
lfortran fortran/uobyqa/trustregion.f90 -c
lfortran fortran/uobyqa/update.f90 -c
lfortran fortran/uobyqa/uobyqb.f90 -c   
lfortran fortran/uobyqa/uobyqa.f90 -c
lfortran c/cintrf.f90 -c
lfortran c/bobyqa_c.f90 -c
lfortran c/cobyla_c.f90 -c
lfortran c/lincoa_c.f90 -c
lfortran c/newuoa_c.f90 -c
lfortran c/uobyqa_c.f90 -c
