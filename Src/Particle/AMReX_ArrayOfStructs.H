#ifndef AMREX_ARRAYOFSTRUCTS_H_
#define AMREX_ARRAYOFSTRUCTS_H_

#include <AMReX_Particle.H>
#include <AMReX_CudaContainers.H>
#include <AMReX_Vector.H>

namespace amrex {

template <int NReal, int NInt>
class ArrayOfStructs {
public:
    using ParticleType  = Particle<NReal, NInt>;
    using RealType      = typename ParticleType::RealType;

    using ParticleVector = Gpu::ManagedDeviceVector<ParticleType>;
    
    using Iterator      = typename ParticleVector::iterator;
    using ConstIterator = typename ParticleVector::const_iterator;
    
    static constexpr int SizeInReal = sizeof(ParticleType) / sizeof(RealType);
    
    const ParticleVector& operator()() const { return m_data; }
    ParticleVector& operator()()       { return m_data; }
    
    std::size_t size () const { return m_data.size(); }
    int numParticles () const { return m_data.size(); }
    
    bool empty () const { return m_data.empty(); }
    
    const RealType* data () const { return &(m_data[0].m_rdata.arr[0]); }
    RealType* data () { return &(m_data[0].m_rdata.arr[0]); }

    const RealType* dataPtr () const { return data(); }
    RealType*       dataPtr ()       { return data(); }
    
    std::pair<int,int> dataShape () const {
	return std::make_pair(SizeInReal, static_cast<int>(m_data.size()));
    }
    
    void push_back (const ParticleType& p) { return m_data.push_back(p); }
    void pop_back() {m_data.pop_back(); }
    bool empty() {return m_data.empty(); }
    
    const ParticleType& back() const {return m_data.back(); }
    ParticleType      & back()       {return m_data.back(); }

    const ParticleType& operator[] (int i) const { return m_data[i]; }
    ParticleType      & operator[] (int i)       { return m_data[i]; }
    
    void resize(size_t count) { m_data.resize(count); }

    Iterator erase( ConstIterator first, ConstIterator second) { return m_data.erase(first, second); }

    template< class InputIt >
    void insert( Iterator pos, InputIt first, InputIt last ) { m_data.insert(pos, first, last); }

    typename ParticleVector::iterator begin () { return m_data.begin(); }
    typename ParticleVector::const_iterator begin () const { return m_data.begin(); }
    typename ParticleVector::const_iterator cbegin () const { return m_data.cbegin(); }
        
    typename ParticleVector::iterator end () { return m_data.end(); }
    typename ParticleVector::const_iterator end () const { return m_data.end(); }
    typename ParticleVector::const_iterator cend () const { return m_data.cend(); }

private:
    ParticleVector m_data;
};
template <int NReal, int NInt> constexpr int ArrayOfStructs<NReal, NInt>::SizeInReal;

} // namespace amrex

#endif // AMREX_ARRAYOFSTRUCTS_H_
