#ifndef _MYPARTICLECONTAINER_H_
#define _MYPARTICLECONTAINER_H_

#include <AMReX_MultiFab.H>
#include <AMReX_MultiFabUtil.H>
#include "AMReX_Particles.H"

namespace amrex {

class MyParticleContainer
    : public ParticleContainer<1+2*BL_SPACEDIM>
{
 public:
  
  using MyParIter = amrex::ParIter<1+2*BL_SPACEDIM>;
  
  MyParticleContainer(const Geometry            & geom, 
		      const DistributionMapping & dmap,
		      const BoxArray            & ba);
  
  void InitParticles(int num_particles, Real mass);
  
  void Deposit(MultiFab& partMF);
  
  void Interpolate(MultiFab& acc);
  
  void Push();  
};

}

#endif // _MYPARTICLECONTAINER_H_
