/*
This is the central piece of code. This file implements a class
(interface in gpuadder.hh) that takes data in on the cpu side, copies
it to the gpu, and exposes functions (increment and retreive) that let
you perform actions with the GPU

This class will get translated into python via swig
*/

#include <kernel.cu>
#include <manager.hh>
#include <assert.h>
#include <iostream>
#include "globalPhenomHM.h"
#include <complex>
#include "cuComplex.h"


using namespace std;

GPUPhenomHM::GPUPhenomHM (double *freqs_,
    int f_length_,
    unsigned int *l_vals_,
    unsigned int *m_vals_,
    int num_modes_,
    int to_gpu_){

    freqs = freqs_;
    f_length = f_length_;
    l_vals = l_vals_;
    m_vals = m_vals_;
    num_modes = num_modes_;
    to_gpu = to_gpu_;

    f_length = f_length_;

    cudaError_t err;

    // DECLARE ALL THE  NECESSARY STRUCTS

    PhenomHMStorage *pHM_trans = new PhenomHMStorage;

    IMRPhenomDAmplitudeCoefficients *pAmp_trans = new IMRPhenomDAmplitudeCoefficients;

    AmpInsPrefactors *amp_prefactors_trans = new AmpInsPrefactors;

    PhenDAmpAndPhasePreComp *pDPreComp_all_trans = new PhenDAmpAndPhasePreComp[num_modes];

    HMPhasePreComp *q_all_trans = new HMPhasePreComp[num_modes];

    std::complex<double> *factorp_trans = new std::complex<double>[num_modes];

    std::complex<double> *factorc_trans = new std::complex<double>[num_modes];

    this->pHM_trans = pHM_trans;
    this->pAmp_trans = pAmp_trans;
    this->pDPreComp_all_trans = pDPreComp_all_trans;
    this->amp_prefactors_trans = amp_prefactors_trans;
    this->q_all_trans = q_all_trans;
    this->factorp_trans = factorp_trans;
    this->factorc_trans = factorc_trans;

  if ((to_gpu == 0) || (to_gpu == 2)){
      printf("cpu\n");
      std::complex<double> *hptilde = new std::complex<double>[num_modes*f_length];
      std::complex<double> *hctilde = new std::complex<double>[num_modes*f_length];
      this->hptilde = hptilde;
      this->hctilde = hctilde;
  }
  if ((to_gpu == 1) || (to_gpu == 2)){

      printf("was here\n");

      double *freqs_geom = new double[f_length];
      this->freqs_geom = freqs_geom;

      double *d_freqs_geom;
      size_t freqs_size = f_length*sizeof(double);
      cudaMalloc(&d_freqs_geom, freqs_size);
      this->d_freqs_geom = d_freqs_geom;

      unsigned int *d_l_vals, *d_m_vals;
      size_t mode_array_size = num_modes*sizeof(unsigned int);
      cudaMalloc(&d_l_vals, mode_array_size);
      cudaMalloc(&d_m_vals, mode_array_size);
      cudaMemcpy(d_l_vals, l_vals, mode_array_size, cudaMemcpyHostToDevice);
      cudaMemcpy(d_m_vals, m_vals, mode_array_size, cudaMemcpyHostToDevice);

      cuDoubleComplex *d_hptilde, *d_hctilde;
      size_t h_size = num_modes*f_length*sizeof(cuDoubleComplex);
      cudaMalloc(&d_hptilde, h_size);
      cudaMalloc(&d_hctilde, h_size);


      // DECLARE ALL THE  NECESSARY STRUCTS

      PhenomHMStorage *d_pHM_trans;
      cudaMalloc(&d_pHM_trans, sizeof(PhenomHMStorage));

      IMRPhenomDAmplitudeCoefficients *d_pAmp_trans;
      cudaMalloc(&d_pAmp_trans, sizeof(IMRPhenomDAmplitudeCoefficients));

      AmpInsPrefactors *d_amp_prefactors_trans;
      cudaMalloc(&d_amp_prefactors_trans, sizeof(AmpInsPrefactors));

      PhenDAmpAndPhasePreComp *d_pDPreComp_all_trans;
      cudaMalloc(&d_pDPreComp_all_trans, num_modes*sizeof(PhenDAmpAndPhasePreComp));

      HMPhasePreComp *d_q_all_trans;
      err = cudaMalloc((void**) &d_q_all_trans, num_modes*sizeof(HMPhasePreComp));
      assert(err == 0);

      cuDoubleComplex *d_factorp_trans, *d_factorc_trans;
      size_t complex_factor_size = num_modes*sizeof(cuDoubleComplex);
      err = cudaMalloc(&d_factorp_trans, complex_factor_size);
      assert(err == 0);
      err = cudaMalloc(&d_factorc_trans, complex_factor_size);
      assert(err == 0);

      double cShift[7] = {0.0,
                           PI_2 /* i shift */,
                           0.0,
                           -PI_2 /* -i shift */,
                           PI /* 1 shift */,
                           PI_2 /* -1 shift */,
                           0.0};

      double *d_cShift;
      err = cudaMalloc(&d_cShift, 7*sizeof(double));
      assert(err == 0);
      err = cudaMemcpy(d_cShift, &cShift, 7*sizeof(double), cudaMemcpyHostToDevice);
      assert(err == 0);

      this->d_l_vals = d_l_vals;
      this->d_m_vals = d_m_vals;
      this->d_hptilde = d_hptilde;
      this->d_hctilde = d_hctilde;
      this->d_pHM_trans = d_pHM_trans;
      this->d_pAmp_trans = d_pAmp_trans;
      this->d_pDPreComp_all_trans = d_pDPreComp_all_trans;
      this->d_amp_prefactors_trans = d_amp_prefactors_trans;
      this->d_q_all_trans = d_q_all_trans;
      this->d_factorp_trans = d_factorp_trans;
      this->d_factorc_trans = d_factorc_trans;
      this->d_cShift = d_cShift;
  }

  NUM_THREADS = 256;
  num_blocks = std::ceil((f_length + NUM_THREADS -1)/NUM_THREADS);
  dim3 gridDim(num_modes, num_blocks);
  printf("blocks %d\n", num_blocks);
  this->gridDim = gridDim;


  //double t0_;
  this->t0 = 0.0;

  //double phi0_;
  this->phi0 = 0.0;

  //double amp0_;
  this->amp0 = 0.0;
}


void GPUPhenomHM::gpu_gen_PhenomHM(
    double m1_, //solar masses
    double m2_, //solar masses
    double chi1z_,
    double chi2z_,
    double distance_,
    double inclination_,
    double phiRef_,
    double deltaF_,
    double f_ref_){

    assert((to_gpu == 1) || (to_gpu == 2));

    GPUPhenomHM::cpu_gen_PhenomHM(
        m1_, //solar masses
        m2_, //solar masses
        chi1z_,
        chi2z_,
        distance_,
        inclination_,
        phiRef_,
        deltaF_,
        f_ref_);


    // Initialize inputs


    // TODO: need to remove this and do more efficiently
    double Mtot_Msun = m1_ + m2_;
    int kk;
    for (kk=0; kk<f_length; kk++){
        freqs_geom[kk] = freqs[kk] * (MTSUN_SI * Mtot_Msun);
    }

    cudaMemcpy(d_freqs_geom, freqs_geom, f_length*sizeof(double), cudaMemcpyHostToDevice);


    cudaError_t err;

    err = cudaMemcpy(d_pHM_trans, pHM_trans, sizeof(PhenomHMStorage), cudaMemcpyHostToDevice);
    assert(err == 0);

    err = cudaMemcpy(d_pAmp_trans, pAmp_trans, sizeof(IMRPhenomDAmplitudeCoefficients), cudaMemcpyHostToDevice);
    assert(err == 0);

    err = cudaMemcpy(d_amp_prefactors_trans, amp_prefactors_trans, sizeof(AmpInsPrefactors), cudaMemcpyHostToDevice);
    assert(err == 0);

    err = cudaMemcpy(d_pDPreComp_all_trans, pDPreComp_all_trans, num_modes*sizeof(PhenDAmpAndPhasePreComp), cudaMemcpyHostToDevice);
    assert(err == 0);

    err = cudaMemcpy(d_q_all_trans, q_all_trans, num_modes*sizeof(HMPhasePreComp), cudaMemcpyHostToDevice);
    assert(err == 0);

    err = cudaMemcpy(d_factorp_trans, factorp_trans, num_modes*sizeof(cuDoubleComplex), cudaMemcpyHostToDevice);
    assert(err == 0);
    err = cudaMemcpy(d_factorc_trans, factorc_trans, num_modes*sizeof(cuDoubleComplex), cudaMemcpyHostToDevice);
    assert(err == 0);


    /* main: evaluate model at given frequencies */

    kernel_calculate_all_modes<<<gridDim, NUM_THREADS>>>(d_hptilde,
          d_hctilde,
          d_l_vals,
          d_m_vals,
          d_pHM_trans,
          d_freqs_geom,
          d_pAmp_trans,
          d_amp_prefactors_trans,
          d_pDPreComp_all_trans,
          d_q_all_trans,
          amp0,
          d_factorp_trans,
          d_factorc_trans,
          num_modes,
          f_length,
          t0,
          phi0,
          d_cShift
      );
     cudaDeviceSynchronize();
     err = cudaGetLastError();
     assert(err == 0);
    /*int i, j;
    printf("f_length %d\n\n", f_length);
    double check;
    for (i=0; i<num_modes; i++){
        for (j=0; j<f_length; j++){
            check = std::real(hptilde[i*f_length + j]);
            if (j % 100 == 0) printf("%e, %e, %e, %e, %e\n", freqs[j], std::real(hptilde[i*f_length + j]), std::imag(hptilde[i*f_length + j]), std::real(hctilde[i*f_length + j]), std::imag(hctilde[i*f_length + j]));
        }
    }
    //this->hptilde = hptilde;
    printf("\n\n\n\n\n\n\n");
     printf("\nhptilde %e\n\n", hptilde[0].real());*/

}


void GPUPhenomHM::cpu_gen_PhenomHM(
    double m1_, //solar masses
    double m2_, //solar masses
    double chi1z_,
    double chi2z_,
    double distance_,
    double inclination_,
    double phiRef_,
    double deltaF_,
    double f_ref_){

    m1 = m1_; //solar masses
    m2 = m2_; //solar masses
    chi1z = chi1z_;
    chi2z = chi2z_;
    distance = distance_;
    inclination = inclination_;
    phiRef = phiRef_;
    deltaF = deltaF_;
    f_ref = f_ref_;

    m1_SI = m1*MSUN_SI;
    m2_SI = m2*MSUN_SI;

    /* main: evaluate model at given frequencies */
    retcode = 0;
    retcode = IMRPhenomHMCore(
        hptilde,
        hctilde,
        freqs,
        f_length,
        m1_SI,
        m2_SI,
        chi1z,
        chi2z,
        distance,
        inclination,
        phiRef,
        deltaF,
        f_ref,
        l_vals,
        m_vals,
        num_modes,
        to_gpu,
        pHM_trans,
        pAmp_trans,
        amp_prefactors_trans,
        pDPreComp_all_trans,
        q_all_trans,
        factorp_trans,
        factorc_trans,
        &t0,
        &phi0,
        &amp0);
    assert (retcode == 1); //,PD_EFUNC, "IMRPhenomHMCore failed in IMRPhenomHM.");
    /*int i, j;
    printf("f_length %d\n\n", f_length);
    double check;
    for (i=0; i<num_modes; i++){
        for (j=0; j<f_length; j++){
            check = std::real(hptilde[i*f_length + j]);
            if (j % 100 == 0) printf("%e, %e, %e, %e, %e\n", freqs[j], std::real(hptilde[i*f_length + j]), std::imag(hptilde[i*f_length + j]), std::real(hctilde[i*f_length + j]), std::imag(hctilde[i*f_length + j]));
        }
    }
    //this->hptilde = hptilde;
    printf("\n\n\n\n\n\n\n");
     printf("\nhptilde %e\n\n", hptilde[0].real());*/

}

void GPUPhenomHM::Get_Waveform (std::complex<double>* hptilde_, std::complex<double>* hctilde_) {
  //hptilde[10] = std::complex<double>(10.0, 9.0);
  //printf("%e\n", hptilde[0].real());
  //printf("%d %d\n", length_, f_length);
if ((this->to_gpu == 0) || (this->to_gpu == 2)){
     memcpy(hptilde_, hptilde, num_modes*f_length*sizeof(std::complex<double>));
     memcpy(hctilde_, hctilde, num_modes*f_length*sizeof(std::complex<double>));
}
  //array_host_[0] = this->hptilde[0];
  //printf("%e\n", array_host_[0].real());
}

void GPUPhenomHM::gpu_Get_Waveform (std::complex<double>* hptilde_, std::complex<double>* hctilde_) {
  //hptilde[10] = std::complex<double>(10.0, 9.0);
  //printf("%e\n", hptilde[0].real());
  //printf("%d %d\n", length_, f_length);
  assert((to_gpu == 1) || (to_gpu == 2));
    cudaError_t err;
     err = cudaMemcpy(hptilde_, d_hptilde, num_modes*f_length*sizeof(std::complex<double>), cudaMemcpyDeviceToHost);
     assert(err == 0);
     cudaMemcpy(hctilde_, d_hctilde, num_modes*f_length*sizeof(std::complex<double>), cudaMemcpyDeviceToHost);
     assert(err == 0);

  //array_host_[0] = this->hptilde[0];
  //printf("%e\n", array_host_[0].real());
}

GPUPhenomHM::~GPUPhenomHM() {
  delete pHM_trans;
  delete pAmp_trans;
  delete amp_prefactors_trans;
  delete pDPreComp_all_trans;
  delete q_all_trans;
  delete factorp_trans;
  delete factorc_trans;

  if ((to_gpu ==0) || (to_gpu == 2)){
      delete hptilde;
      delete hctilde;
  }
  if ((to_gpu == 1) || (to_gpu == 2)){
      delete freqs_geom;
      cudaFree(d_freqs_geom);
      cudaFree(d_l_vals);
      cudaFree(d_m_vals);
      cudaFree(d_pHM_trans);
      cudaFree(d_pAmp_trans);
      cudaFree(d_amp_prefactors_trans);
      cudaFree(d_pDPreComp_all_trans);
      cudaFree(d_q_all_trans);
      cudaFree(d_factorp_trans);
      cudaFree(d_factorc_trans);
      cudaFree(d_hptilde);
      cudaFree(d_hctilde);
      cudaFree(d_cShift);
  }
}
