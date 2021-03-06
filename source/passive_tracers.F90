!|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

 module passive_tracers

!BOP
! !MODULE: passive_tracers

! !DESCRIPTION:
!  This module provides support for passive tracers.
!  The base model calls subroutines in this module which then call
!     subroutines in individual passive tracer modules.

! !REVISION HISTORY:
!  SVN:$Id: passive_tracers.F90 13819 2009-01-08 03:02:14Z njn01 $

! !USES:

   use POP_KindsMod
   use POP_ErrorMod
   use POP_IOUnitsMod

   use kinds_mod, only: r8, int_kind, log_kind, char_len
   use blocks, only: block, nx_block, ny_block
   use domain_size, only: max_blocks_clinic, km, nt
   use domain, only: nblocks_clinic
   use communicate, only: my_task, master_task
   use broadcast, only: broadcast_scalar
   use prognostic, only: TRACER, tracer_d, curtime, oldtime
   use forcing_shf, only: SHF_QSW_RAW, SHF_QSW
   use io_types, only: stdout, nml_in, nml_filename, io_field_desc, &
       datafile
   use exit_mod, only: sigAbort, exit_pop
   use timers, only: timer_start, timer_stop
   use tavg, only: define_tavg_field, ltavg_on, &
       tavg_requested, accumulate_tavg_field
   use movie, only: define_movie_field, movie_requested, &
       update_movie_field
   use constants, only: c0, c1, p5, delim_fmt, char_blank, &
       salt_to_ppt, ocn_ref_salinity, ppt_to_salt, sea_ice_salinity
   use time_management, only: mix_pass
   use grid, only: partial_bottom_cells, DZT, dz
   use registry, only: register_string, registry_match
   use io_tools, only: document

   use iage_mod, only:             &
       iage_tracer_cnt,            &
       iage_init,                  &
       iage_set_interior,          &
       iage_reset

   use dye_mod, only:             &
       dye_tracer_cnt,            &
       dye_init,                  &
       dye_set_interior,          &
       dye_set_sflux,             &
       dye_movie,                 &
       dye_reset

   implicit none
   private
   save

! !PUBLIC MEMBER FUNCTIONS:

   public ::                                 &
      init_passive_tracers,                  &
      set_interior_passive_tracers,          &
      set_sflux_passive_tracers,             &
      reset_passive_tracers,                 &
      write_restart_passive_tracers,         &
      tavg_passive_tracers,                  &
      movie_passive_tracers,                 &
      passive_tracers_tavg_sflux,            &
      passive_tracers_tavg_fvice,            &
      tracer_ref_val,                        &
      tadvect_ctype_passive_tracers

!EOP
!BOC

!-----------------------------------------------------------------------
!  tavg ids for automatically generated tavg passive-tracer fields
!-----------------------------------------------------------------------

   integer (int_kind), dimension (3:nt) ::  &
      tavg_var,        & ! tracer
      tavg_var_sqr,    & ! tracer square
      tavg_var_J,      & ! tracer source sink term
      tavg_var_Jint,   & ! vertically integrated tracer source sink term
      tavg_var_stf,    & ! tracer surface flux
      tavg_var_resid,  & ! tracer residual surface flux
      tavg_var_fvper,  & ! virtual tracer flux from precip,evap,runoff
      tavg_var_fvice     ! virtual tracer flux from ice formation

!-----------------------------------------------------------------------
!  array containing advection type for each passive tracer
!-----------------------------------------------------------------------

   character (char_len), dimension(3:nt) :: &
      tadvect_ctype_passive_tracers

!-----------------------------------------------------------------------
!  PER virtual fluxes. The application of the flux happens in surface
!  forcing subroutines, before tavg flags are set, so the tavg accumulation
!  must be in a different subroutine than the application. The fluxes
!  are stored to avoid recomputing them when accumulating.
!-----------------------------------------------------------------------

   real (r8), dimension(:,:,:,:), allocatable :: FvPER

!-----------------------------------------------------------------------
!  logical variables that denote if a passive tracer module is on
!-----------------------------------------------------------------------

   logical (kind=log_kind) ::  &
      iage_on, dye_on

   namelist /passive_tracers_on_nml/  &
      iage_on, dye_on

!-----------------------------------------------------------------------
!     index bounds of passive tracer module variables in TRACER
!-----------------------------------------------------------------------

   integer (kind=int_kind) ::                       &
      iage_ind_begin,       iage_ind_end, &
      dye_ind_begin,        dye_ind_end

!-----------------------------------------------------------------------
!  filtered SST and SSS, if needed
!-----------------------------------------------------------------------

   logical (kind=log_kind) :: filtered_SST_SSS_needed

   real (r8), dimension(:,:,:), allocatable :: &
      SST_FILT,      & ! SST with time filter applied, [degC]
      SSS_FILT         ! SSS with time filter applied, [psu]

!EOC
!***********************************************************************

 contains

!***********************************************************************
!BOP
! !IROUTINE: init_passive_tracers
! !INTERFACE:

 subroutine init_passive_tracers(init_ts_file_fmt, &
                                 read_restart_filename, errorCode)

! !DESCRIPTION:
!  Initialize passive tracers. This involves:
!  1) reading passive_tracers_on_nml to see which module are on
!  2) setting tracer module index bounds
!  3) calling tracer module init subroutine
!  4) define common tavg fields
!  5) set up space for storing virtual fluxes
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   character (*), intent(in) ::  &
      init_ts_file_fmt,    & ! format (bin or nc) for input file
      read_restart_filename  ! file name for restart file

! !OUTPUT PARAMETERS:

   integer (POP_i4), intent(out) :: &
      errorCode

!EOP
!BOC
!-----------------------------------------------------------------------
!  local variables
!-----------------------------------------------------------------------

   character(*), parameter :: subname = 'passive_tracers:init_passive_tracers'

   integer (int_kind) :: cumulative_nt, n, &
      nml_error,        &! error flag for nml read
      iostat             ! io status flag

   character (char_len) :: sname, lname, units

!-----------------------------------------------------------------------
!  register init_passive_tracers
!-----------------------------------------------------------------------

   errorCode = POP_Success

   call register_string('init_passive_tracers')

   iage_on      = .false.
   dye_on       = .false.

   if (my_task == master_task) then
      open (nml_in, file=nml_filename, status='old', iostat=nml_error)
      if (nml_error /= 0) then
        nml_error = -1
      else
        nml_error =  1
      endif
      !*** keep reading until find right namelist
      do while (nml_error > 0)
        read(nml_in, nml=passive_tracers_on_nml,iostat=nml_error)
      end do
      if (nml_error == 0) close(nml_in)
   end if

   call broadcast_scalar(nml_error, master_task)
   if (nml_error /= 0) then
      call exit_POP(sigAbort,'ERROR reading passive_tracers_on namelist')
   endif
                                                                                

   if (my_task == master_task) then
      write(stdout,*) ' '
      write(stdout,*) ' Document Namelist Parameters:'
      write(stdout,*) ' ============================ '
      write(stdout,*) ' '
      write(stdout, passive_tracers_on_nml)
      write(stdout,*) ' '
      call POP_IOUnitsFlush(POP_stdout)
   endif

   call broadcast_scalar(iage_on,   master_task)
   call broadcast_scalar(dye_on,   master_task)

!-----------------------------------------------------------------------
!  default is for tracers to use same advection scheme as the base model
!-----------------------------------------------------------------------

   tadvect_ctype_passive_tracers(3:nt) = 'base_model'

!-----------------------------------------------------------------------
!  set up indices for passive tracer modules that are on
!-----------------------------------------------------------------------

   cumulative_nt = 2

   if (iage_on) then
      call set_tracer_indices('IAGE', iage_tracer_cnt, cumulative_nt,  &
                              iage_ind_begin, iage_ind_end)
   end if

   if (dye_on) then
      call set_tracer_indices('DYE', dye_tracer_cnt, cumulative_nt,  &
                              dye_ind_begin, dye_ind_end)
   end if

   if (cumulative_nt /= nt) then
      call document(subname, 'nt', nt)
      call document(subname, 'cumulative_nt', cumulative_nt)
      call exit_POP(sigAbort, &
         'ERROR in init_passive_tracers: declared nt does not match cumulative nt')
   end if

!-----------------------------------------------------------------------
!  Ideal Age (IAGE) block
!-----------------------------------------------------------------------

   if (iage_on) then
      call iage_init(init_ts_file_fmt, read_restart_filename, &
                     tracer_d(iage_ind_begin:iage_ind_end), &
                     TRACER(:,:,:,iage_ind_begin:iage_ind_end,:,:), &
                     errorCode)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'init_passive_tracers: error in iage_init')
         return
      endif

   end if

!-----------------------------------------------------------------------
!  Passive Dye (DYE) block
!-----------------------------------------------------------------------

   if (dye_on) then
      call dye_init(init_ts_file_fmt, read_restart_filename, &
                     tracer_d(dye_ind_begin:dye_ind_end), &
                     TRACER(:,:,:,dye_ind_begin:dye_ind_end,:,:), &
                     tadvect_ctype_passive_tracers(dye_ind_begin:dye_ind_end), &
                     errorCode)

      if (errorCode /= POP_Success) then
         call POP_ErrorSet(errorCode, &
            'init_passive_tracers: error in dye_init')
         return
      endif

   end if

!-----------------------------------------------------------------------
!  print out tracer names from tracer modules that are on
!-----------------------------------------------------------------------

   if (my_task == master_task) then
      write(stdout,delim_fmt)
      write(stdout,*) 'TRACER INDEX    TRACER NAME'
      write(stdout,1010) 1, 'TEMP'
      write(stdout,1010) 2, 'SALT'
      call POP_IOUnitsFlush(POP_stdout)
      do n = 3, nt
         write(stdout,1010) n, TRIM(tracer_d(n)%long_name)
         call POP_IOUnitsFlush(POP_stdout)
      enddo
      write(stdout,delim_fmt)
      call POP_IOUnitsFlush(POP_stdout)
   end if

!-----------------------------------------------------------------------
!  generate common tavg fields for all tracers
!-----------------------------------------------------------------------

   do n = 3, nt
      sname = tracer_d(n)%short_name
      lname = tracer_d(n)%long_name
      units = tracer_d(n)%units
      call define_tavg_field(tavg_var(n),                           &
                             sname, 3, long_name=lname,             &
                             units=units, grid_loc='3111')

      sname = trim(tracer_d(n)%short_name) /&
                                            &/ '_SQR'
      lname = trim(tracer_d(n)%long_name) /&
                                           &/ ' Squared'
      units = '(' /&
                   &/ tracer_d(n)%units /&
                                         &/ ')^2'
      call define_tavg_field(tavg_var_sqr(n),                       &
                             sname, 3, long_name=lname,             &
                             units=units, grid_loc='3111')

      sname = 'J_' /&
                    &/ trim(tracer_d(n)%short_name)
      lname = trim(tracer_d(n)%long_name) /&
                                           &/ ' Source Sink Term'
      units = tracer_d(n)%tend_units
      call define_tavg_field(tavg_var_J(n),                         &
                             sname, 3, long_name=lname,             &
                             units=units, grid_loc='3111')

      sname = 'Jint_' /&
                       &/ trim(tracer_d(n)%short_name)
      lname = trim(tracer_d(n)%long_name) /&
                                           &/ ' Source Sink Term Vertical Integral'
      units = tracer_d(n)%flux_units
      call define_tavg_field(tavg_var_Jint(n),                      &
                             sname, 2, long_name=lname,             &
                             units=units, grid_loc='2110')

      sname = 'STF_' /&
                      &/ trim(tracer_d(n)%short_name)
      lname = trim(tracer_d(n)%long_name) /&
                                           &/ ' Surface Flux'
      units = tracer_d(n)%flux_units
      call define_tavg_field(tavg_var_stf(n),                       &
                             sname, 2, long_name=lname,             &
                             units=units, grid_loc='2110')

      sname = 'RESID_' /&
                        &/ trim(tracer_d(n)%short_name)
      lname = trim(tracer_d(n)%long_name) /&
                                           &/ ' Residual Surface Flux'
      units = tracer_d(n)%flux_units
      call define_tavg_field(tavg_var_resid(n),                     &
                             sname, 2, long_name=lname,             &
                             units=units, grid_loc='2110')

      sname = 'FvPER_' /&
                        &/ trim(tracer_d(n)%short_name)
      lname = trim(tracer_d(n)%long_name) /&
                                           &/ ' Virtual Surface Flux, PER'
      units = tracer_d(n)%flux_units
      call define_tavg_field(tavg_var_fvper(n),                     &
                             sname, 2, long_name=lname,             &
                             units=units, grid_loc='2110')

   enddo

!-----------------------------------------------------------------------
!  allocate and initialize storage for virtual fluxes
!-----------------------------------------------------------------------

   allocate(FvPER(nx_block,ny_block,3:nt,nblocks_clinic))
   FvPER = c0

 1010 format(5X,I2,10X,A)

!-----------------------------------------------------------------------
!EOC

 end subroutine init_passive_tracers

!***********************************************************************
!BOP
! !IROUTINE: set_interior_passive_tracers
! !INTERFACE:

 subroutine set_interior_passive_tracers(k, this_block, TRACER_SOURCE)

! !DESCRIPTION:
!  call subroutines for each tracer module that compute source-sink terms
!  accumulate commnon tavg fields related to source-sink terms
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   integer (int_kind), intent(in) :: k  ! vertical level index

   type (block), intent(in) :: &
      this_block   ! block information for this block

! !INPUT/OUTPUT PARAMETERS:

   real (r8), dimension(nx_block,ny_block,nt), intent(inout) :: &
      TRACER_SOURCE

!EOP
!BOC
!-----------------------------------------------------------------------
!  local variables
!-----------------------------------------------------------------------

   integer (int_kind) ::  &
      bid,                & ! local block address for this block
      n                     ! tracer index

   real (r8), dimension(nx_block,ny_block) :: &
      WORK

!-----------------------------------------------------------------------

   bid = this_block%local_id

!-----------------------------------------------------------------------
!  Ideal Age (IAGE) block
!-----------------------------------------------------------------------

   if (iage_on) then
      call iage_set_interior(k,                                    &
         TRACER_SOURCE (:,:,iage_ind_begin:iage_ind_end) )
   end if

!-----------------------------------------------------------------------
!  Passive Dye (DYE) block
!-----------------------------------------------------------------------

   if (dye_on) then
      call dye_set_interior(k,                                    &
         TRACER_SOURCE (:,:,dye_ind_begin:dye_ind_end) )
   end if

!-----------------------------------------------------------------------
!  accumulate time average if necessary
!-----------------------------------------------------------------------

   if (ltavg_on .and. mix_pass /= 1) then
      do n = 3, nt
         if (tavg_requested(tavg_var_J(n))) then
            call accumulate_tavg_field(TRACER_SOURCE(:,:,n),tavg_var_J(n),bid,k)
         endif

         if (tavg_requested(tavg_var_Jint(n))) then
            if (partial_bottom_cells) then
               WORK = TRACER_SOURCE(:,:,n) * DZT(:,:,k,bid)
            else
               WORK = TRACER_SOURCE(:,:,n) * dz(k)
            endif
            call accumulate_tavg_field(WORK,tavg_var_Jint(n),bid,k)
         endif
      enddo
   endif

!-----------------------------------------------------------------------
!EOC

 end subroutine set_interior_passive_tracers

!***********************************************************************
!BOP
! !IROUTINE: set_sflux_passive_tracers
! !INTERFACE:

 subroutine set_sflux_passive_tracers(U10_SQR,ICE_FRAC,PRESS,STF)

! !DESCRIPTION:
!  call subroutines for each tracer module that compute surface fluxes
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   real (r8), dimension(nx_block,ny_block,max_blocks_clinic), intent(in) ::   &
      U10_SQR,  & ! 10m wind speed squared
      ICE_FRAC, & ! sea ice fraction (non-dimensional)
      PRESS       ! sea level atmospheric pressure (Pascals)

! !INPUT/OUTPUT PARAMETERS:

   real (r8), dimension(nx_block,ny_block,nt,max_blocks_clinic), intent(inout) :: &
      STF   ! surface fluxes for tracers

!EOP
!BOC
!-----------------------------------------------------------------------
!  local variables
!-----------------------------------------------------------------------

   logical (kind=log_kind) :: first_call = .true.
   real (r8)          :: ref_val
   integer (int_kind) :: iblock, n

!-----------------------------------------------------------------------

   if (first_call) then
      call register_string('set_sflux_passive_tracers')
   end if

!-----------------------------------------------------------------------
!  compute filtered SST and SSS, if needed
!-----------------------------------------------------------------------

   if (filtered_SST_SSS_needed) then
      !$OMP PARALLEL DO PRIVATE(iblock,n,ref_val)
      do iblock = 1,nblocks_clinic
         SST_FILT(:,:,iblock) = p5*(TRACER(:,:,1,1,oldtime,iblock) + &
                                    TRACER(:,:,1,1,curtime,iblock))
         SSS_FILT(:,:,iblock) = p5*(TRACER(:,:,1,2,oldtime,iblock) + &
                                    TRACER(:,:,1,2,curtime,iblock)) * salt_to_ppt
      end do
      !$OMP END PARALLEL DO
   end if

!-----------------------------------------------------------------------
!  IAGE does not have surface fluxes
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!  DYE block
!-----------------------------------------------------------------------

   if (dye_on) then
      call dye_set_sflux(                                         &
         STF(:,:,dye_ind_begin:dye_ind_end,:))
   end if

!-----------------------------------------------------------------------

   first_call = .false.

!-----------------------------------------------------------------------
!EOC

 end subroutine set_sflux_passive_tracers

!***********************************************************************
!BOP
! !IROUTINE: write_restart_passive_tracers
! !INTERFACE:

 subroutine write_restart_passive_tracers(restart_file, action)

! !DESCRIPTION:
!  call restart routines for each tracer module that
!  write fields besides the tracers themselves
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   character(*), intent(in) :: action

! !INPUT/OUTPUT PARAMETERS:

   type (datafile), intent (inout)  :: restart_file

!EOP
!BOC

!-----------------------------------------------------------------------
!  IAGE does not write additional restart fields
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!EOC

 end subroutine write_restart_passive_tracers

!***********************************************************************
!BOP
! !IROUTINE: reset_passive_tracers
! !INTERFACE:

 subroutine reset_passive_tracers(TRACER_NEW)

! !DESCRIPTION:
!  call subroutines for each tracer module to reset tracer values
!
! !REVISION HISTORY:
!  same as module

! !INPUT/OUTPUT PARAMETERS:

   real(r8), dimension(nx_block,ny_block,km,nt), intent(inout) :: &
      TRACER_NEW      ! all tracers at new time for a given block

!EOP
!BOC

!-----------------------------------------------------------------------
!  ECOSYS does not reset values
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!  CFC does not reset values
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!  IAGE block
!-----------------------------------------------------------------------

   if (iage_on) then
      call iage_reset(  &
         TRACER_NEW(:,:,:,iage_ind_begin:iage_ind_end) )
   end if

!-----------------------------------------------------------------------
!  Passive Dye (DYE) block
!-----------------------------------------------------------------------

   if (dye_on) then
      call dye_reset(  &
         TRACER_NEW(:,:,:,dye_ind_begin:dye_ind_end) )
   end if

!-----------------------------------------------------------------------
!EOC

 end subroutine reset_passive_tracers

!***********************************************************************
!BOP
! !IROUTINE: tavg_passive_tracers
! !INTERFACE:

 subroutine tavg_passive_tracers(bid, k)

! !DESCRIPTION:
!  accumulate common tavg fields for tracers
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   integer (int_kind), intent(in) :: k, bid  ! vertical level index

!EOP
!BOC
!-----------------------------------------------------------------------
!  local variables
!-----------------------------------------------------------------------

   integer (int_kind) ::  &
      n                     ! tracer index

   real (r8), dimension(nx_block,ny_block) :: &
      WORK

!-----------------------------------------------------------------------

   if (ltavg_on .and. mix_pass /= 1) then
      do n = 3, nt
         if (tavg_requested(tavg_var(n))) then
            call accumulate_tavg_field(TRACER(:,:,k,n,curtime,bid),tavg_var(n),bid,k)
         endif

         if (tavg_requested(tavg_var_sqr(n))) then
            WORK = TRACER(:,:,k,n,curtime,bid) ** 2
            call accumulate_tavg_field(WORK,tavg_var_sqr(n),bid,k)
         endif
      enddo
   endif

 end subroutine tavg_passive_tracers

!-----------------------------------------------------------------------
!EOC

!***********************************************************************
!BOP
! !IROUTINE: passive_tracers_tavg_sflux
! !INTERFACE:

 subroutine passive_tracers_tavg_sflux(STF)

! !DESCRIPTION:
!  accumulate common tavg fields for tracer surface fluxes
!  call accumation subroutines for tracer modules that have additional
!     tavg fields related to surface fluxes
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

  real(r8), dimension(nx_block,ny_block,nt,max_blocks_clinic), &
      intent(in) :: STF

!EOP
!BOC
!-----------------------------------------------------------------------
!  local variables
!-----------------------------------------------------------------------

   integer (int_kind) :: iblock, n

!-----------------------------------------------------------------------
!  accumulate surface flux and FvPER flux for all tracers
!-----------------------------------------------------------------------

   if (ltavg_on) then
      !$OMP PARALLEL DO PRIVATE(iblock,n)
      do iblock = 1,nblocks_clinic
         do n = 3, nt
            if (tavg_requested(tavg_var_stf(n))) then
               call accumulate_tavg_field(STF(:,:,n,iblock),tavg_var_stf(n),iblock,1)
            endif

            if (tavg_requested(tavg_var_fvper(n))) then
               call accumulate_tavg_field(FvPER(:,:,n,iblock),tavg_var_fvper(n),iblock,1)
            endif
         enddo
      enddo
      !$OMP END PARALLEL DO
   endif

!-----------------------------------------------------------------------
!  call routines from modules that have additional sflux tavg fields
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!  IAGE does not have additional sflux tavg fields
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!EOC

 end subroutine passive_tracers_tavg_sflux

!***********************************************************************
!BOP
! !IROUTINE: passive_tracers_tavg_FvICE
! !INTERFACE:

 subroutine passive_tracers_tavg_FvICE(cp_over_lhfusion, QICE)

! !DESCRIPTION:
!  accumulate FvICE fluxes passive tracers
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   real (r8), dimension(nx_block,ny_block,max_blocks_clinic), intent(in) :: &
      QICE                ! tot column cooling from ice form (in C*cm)

   real (r8), intent(in) ::  &
      cp_over_lhfusion    ! cp_sw/latent_heat_fusion

!EOP
!BOC
!-----------------------------------------------------------------------
!  local variables
!-----------------------------------------------------------------------

   real (r8), dimension(nx_block,ny_block) :: &
      WORK

   real (r8) ::        &
      ref_val   ! temporary work array

   integer (int_kind) :: iblock, n

!-----------------------------------------------------------------------

   if (ltavg_on) then
      !$OMP PARALLEL DO PRIVATE(iblock,n,ref_val,WORK)
      do iblock = 1,nblocks_clinic
         do n = 3, nt
            if (tavg_requested(tavg_var_fvice(n))) then
               ref_val = tracer_ref_val(n)
               if (ref_val /= c0)  then
                  WORK = ref_val * (c1 - sea_ice_salinity / ocn_ref_salinity) * &
                     cp_over_lhfusion * max(c0, QICE(:,:,iblock))
                  call accumulate_tavg_field(WORK,tavg_var_fvice(n),iblock,1)
               endif
            endif
         enddo
      enddo
      !$OMP END PARALLEL DO
   endif

!-----------------------------------------------------------------------
!EOC

 end subroutine passive_tracers_tavg_FvICE

!***********************************************************************
!BOP
! !IROUTINE: set_tracer_indices
! !INTERFACE:

 subroutine set_tracer_indices(module_string, module_nt,  &
        cumulative_nt, ind_begin, ind_end)

! !DESCRIPTION:
!  set the index bounds of a single passive tracer module
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   character (*), intent(in) :: &
      module_string

   integer (kind=int_kind), intent(in) ::  &
      module_nt

! !INPUT/OUTPUT PARAMETERS:

   integer (kind=int_kind), intent(inout) ::  &
      cumulative_nt

   integer (kind=int_kind), intent(out) ::  &
      ind_begin, &
      ind_end

!EOP
!BOC
!-----------------------------------------------------------------------
!  local variables
!-----------------------------------------------------------------------

   character(*), parameter :: subname = 'passive_tracers:set_tracer_indices'

   character (char_len) ::  &
      error_string

!-----------------------------------------------------------------------

   ind_begin = cumulative_nt + 1
   ind_end = ind_begin + module_nt - 1
   cumulative_nt = ind_end

   if (my_task == master_task) then
      write(stdout,delim_fmt)
      write(stdout,*) module_string /&
         &/ ' ind_begin = ', ind_begin
      write(stdout,*) module_string /&
         &/ ' ind_end   = ', ind_end
      write(stdout,delim_fmt)
   end if

   if (cumulative_nt > nt) then
      call document(subname, 'nt', nt)
      call document(subname, 'cumulative_nt', cumulative_nt)
      error_string = 'nt too small for module ' /&
         &/ module_string
      call exit_POP(sigAbort, error_string)
   end if

!-----------------------------------------------------------------------
!EOC

 end subroutine set_tracer_indices

!***********************************************************************
!BOP
! !IROUTINE: tracer_ref_val
! !INTERFACE:

 function tracer_ref_val(ind)

! !DESCRIPTION:
!  return reference value for tracer with global tracer index ind
!  this is used in virtual flux computations
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   integer(int_kind), intent(in) :: ind

! !OUTPUT PARAMETERS:

   real(r8) :: tracer_ref_val

!EOP
!BOC

!-----------------------------------------------------------------------
!  default value for reference value is 0
!-----------------------------------------------------------------------

   tracer_ref_val = c0

!-----------------------------------------------------------------------
!  IAGE does not use virtual fluxes
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!EOC

 end function tracer_ref_val

!***********************************************************************
!BOP
! !IROUTINE: movie_passive_tracers
! !INTERFACE:

 subroutine movie_passive_tracers(bid)

! !DESCRIPTION:
!  driver for creating movie fields of passive tracers
!
! !REVISION HISTORY:
!  same as module

! !INPUT PARAMETERS:

   integer (POP_i4), intent(in) :: bid  ! block index

!EOP
!BOC
!-----------------------------------------------------------------------
!-----------------------------------------------------------------------
!  Ideal Age (IAGE) block
!  no IAGE movie fields
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!  Passive Dye (DYE) block
!-----------------------------------------------------------------------

   if (dye_on) then
      call dye_movie(bid,   &
         TRACER(:,:,:,dye_ind_begin:dye_ind_end,curtime,bid))
   end if

 end subroutine movie_passive_tracers

!***********************************************************************

 end module passive_tracers

!|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
