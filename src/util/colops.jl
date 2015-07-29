### GENERALIZED COLUMN OPS

# We want to support arbitrary dimensional arrays.  When data comes in
# N dimensions, we assume it is an array of N-1 dimensional instances
# and the last dimension gives us the instance count.  We will refer
# to the first N-1 dimensions as generalized "columns" of the
# data. These columns are indexed by the last index of an array,
# i.e. column i corresponds to b[:,:,...,i].


# CSLICE!  Returns a slice of array b, with columns specified in range
# r, using the storage in KUarray a.  The element types need to match,
# but the size of a does not need to match, it is adjusted as
# necessary.  This is used in train and predict to get data from a raw
# array into a KUarray for minibatching.

cslice!{A,B,T}(a::KUdense{A,T}, b::KUdense{B,T}, r::UnitRange)=cslice!(a,b.arr,r)

function cslice!{A,T}(a::KUdense{A,T}, b::BaseArray{T}, r::UnitRange)
    n  = clength(b) * length(r)
    length(a.ptr) >= n || resize!(a.ptr, int(resizefactor(KUdense)*n+1))
    b1 = 1 + clength(b) * (first(r) - 1)
    copy!(a.ptr, 1, b, b1, n)
    a.arr = arr(a.ptr, csize(b, length(r)))
    return a
end

function cslice!{A,B,T,I}(a::KUsparse{A,T,I}, b::Sparse{B,T,I}, r::UnitRange)
    bptr = to_host(b.colptr)
    nz = 0; for i in r; nz += bptr[i+1]-bptr[i]; end
    a.m = b.m
    a.n = length(r)
    resize!(a.nzval, nz)
    resize!(a.rowval, nz)
    aptr = Array(I, a.n+1)
    aptr[1] = a1 = aj = 1
    for bj in r                 # copy column b[:,bj] to a[:,aj]
        b1 = bptr[bj]
        nz = bptr[bj+1]-b1
        copy!(a.nzval.arr, a1, b.nzval, b1, nz)
        copy!(a.rowval.arr, a1, b.rowval, b1, nz)
        a1 += nz
        aptr[aj+=1] = a1
    end
    @assert aj == a.n+1
    copy!(a.colptr, aptr)
    return a
end

cslice!{A,B,T,I}(a::KUsparse{A,T,I}, b::KUsparse{B,T,I}, r::UnitRange)=
    cslice!(a, convert(Sparse, b), r)

cslice!{A,T,I}(a::KUsparse{A,T,I}, b::SparseMatrixCSC{T,I}, r::UnitRange)=
    cslice!(a, convert(Sparse, b), r)

# CCOPY! Copy n columns from src starting at column si, into dst
# starting at column di.  Used by predict to construct output.  
# Don't need the sparse version, output always dense.

ccopy!{A,T,N}(dst::BaseArray{T,N}, di, src::KUdense{A,T,N}, si=1, n=ccount(src)-si+1)=(ccopy!(dst,di,src.arr,si,n); dst)
ccopy!{A,B,T,N}(dst::KUdense{A,T,N}, di, src::KUdense{B,T,N}, si=1, n=ccount(src)-si+1)=(ccopy!(dst.arr,di,src.arr,si,n); dst)

function ccopy!{T,N}(dst::BaseArray{T,N}, di, src::BaseArray{T,N}, si=1, n=ccount(src)-si+1)
    @assert csize(dst)==csize(src)
    clen = clength(src)
    d1 = 1 + clen * (di - 1)
    s1 = 1 + clen * (si - 1)
    copy!(dst, d1, src, s1, clen * n)
    return dst
end

# CADD! Add n columns from src starting at column si, into dst
# starting at column di.  Used by uniq!  Don't need sparse version,
# weights always dense.

using Base.LinAlg: axpy!

cadd!{A,T,N}(dst::BaseArray{T,N}, di, src::KUdense{A,T,N}, si=1, n=ccount(src)-si+1)=(cadd!(dst,di,src.arr,si,n); dst)
cadd!{A,B,T,N}(dst::KUdense{A,T,N}, di, src::KUdense{B,T,N}, si=1, n=ccount(src)-si+1)=(cadd!(dst.arr,di,src.arr,si,n); dst)

function cadd!{T,N}(dst::BaseArray{T,N}, di, src::BaseArray{T,N}, si=1, n=ccount(src)-si+1)
    @assert csize(dst)==csize(src)
    @assert ccount(dst) >= di+n-1
    @assert ccount(src) >= si+n-1
    clen = clength(src)
    d1 = 1 + clen * (di - 1)
    s1 = 1 + clen * (si - 1)
    n1 = clen * n
    axpy!(n1, one(T), pointer(src, s1), 1, pointer(dst, d1), 1)
    return dst
end

# CCAT! generalizes append! to multi-dimensional arrays.  Adds the
# ability to specify particular columns to append.  Used in
# kperceptron to add support vectors.

ccat!{A,B,T,N}(a::KUdense{A,T,N}, b::KUdense{B,T,N}, cols=(1:ccount(b)))=ccat!(a,b.arr,cols)

function ccat!{A,T,N}(a::KUdense{A,T,N}, b::BaseArray{T,N}, cols=(1:ccount(b)))
    @assert csize(a)==csize(b)
    alen = length(a)
    clen = clength(a)
    ncols = length(cols)
    n = alen + ncols * clen
    length(a.ptr) >= n || resize!(a.ptr, int(resizefactor(KUdense)*n+1))
    for i=1:ncols
        bidx = (cols[i]-1)*clen + 1
        copy!(a.ptr, alen+1, b, bidx, clen)
        alen += clen
    end
    a.arr = arr(a.ptr, csize(a, ccount(a) + ncols))
    return a
end

ccat!{A,B,T}(a::KUsparse{A,T}, b::Sparse{B,T}, cols=(1:ccount(b)))=ccat!(a,convert(KUsparse,b),cols)
ccat!{A,T}(a::KUsparse{A,T}, b::SparseMatrixCSC{T}, cols=(1:ccount(b)))=ccat!(a,convert(KUsparse,b),cols)

function ccat!{A,B,T}(a::KUsparse{A,T}, b::KUsparse{B,T}, cols=(1:ccount(b)))
    # a: m, n, colptr, rowval, nzval
    # colptr[i]: starting index (in rowval,nzval) of column i
    # colptr[n+1]: nz+1
    @assert size(a,1) == size(b,1)
    aptr = to_host(a.colptr.arr)
    bptr = to_host(b.colptr.arr)
    na = aptr[a.n+1]-1          # count new nonzero entries in a
    ncols = length(cols)
    for i in cols; na += bptr[i+1]-bptr[i]; end
    resize!(a.nzval, na)
    resize!(a.rowval, na)
    na = aptr[a.n+1]-1          # restart the count
    for i=1:ncols
        bj=cols[i]              # bj'th column of b
        aj=a.n+i                # will become aj'th column of a
        nz=bptr[bj+1]-bptr[bj]  # with nz nonzero values
        @assert length(aptr) == aj
        push!(aptr, aptr[aj]+nz) # aptr[aj+1] = aptr[aj]+nz
        copy!(a.nzval.arr,na+1,b.nzval.arr,bptr[bj],nz)
        copy!(a.rowval.arr,na+1,b.rowval.arr,bptr[bj],nz)
        na = na+nz
    end
    @assert length(aptr) == a.n + ncols + 1
    resize!(a.colptr, a.n + ncols + 1)
    copy!(a.colptr.arr, a.n+2, aptr, a.n+2, ncols)
    a.n += ncols
    return a
end

### UNIQ! leaves unique columns in its first argument and sums to
### corresponding columns in the remaining arguments.  Used by
### kperceptron in merging identical support vectors.

function uniq!{A<:Array}(s::KUdense{A}, ww::KUdense...)
    oldn = ccount(s)                                            # number of original support vectors
    for w in ww; @assert ccount(w) == oldn; end 
    ds = Dict{Any,Int}()                                        # support vector => new index
    newn = 0                                                    # number of new support vectors
    for oldj=1:oldn
        newj = get!(ds, _colkey(s,oldj), newn+1)
        if newj <= newn                                         # s[:,oldj] already in s[:,newj]
            @assert newj <= newn == length(ds) < oldj
            for w in ww; cadd!(w,newj,w,oldj,1); end
        else                                                    # s[:,oldj] to be copied to s[:,newj]                    
            @assert newj == newn+1 == length(ds) <= oldj	
            newn += 1
            if newj != oldj
                ccopy!(s,newj,s,oldj,1)
                for w in ww; ccopy!(w,newj,w,oldj,1); end
            end
        end
    end
    @assert newn == length(ds)
    resize!(s, csize(s, newn))
    for w in ww; resize!(w, csize(w, newn)); end
    return tuple(s, ww...)
end

function uniq!{A<:Array}(s::KUsparse{A}, ww::KUdense...)
    oldn = ccount(s)                                            # number of original support vectors
    for w in ww; @assert ccount(w) == oldn; end 
    ds = Dict{Any,Int}()                                        # support vector => new index
    @assert s.colptr.arr[1]==1
    ncol = 0
    nnz = 0
    for oldj=1:oldn
        newj = get!(ds, _colkey(s,oldj), ncol+1)
        if newj <= ncol                                          # s[:,oldj] already in s[:,newj]
            @assert newj <= length(ds) == ncol < oldj
            for w in ww; cadd!(w,newj,w,oldj,1); end
        else                                                    # s[:,oldj] to be copied to s[:,newj]                    
            @assert newj == ncol+1 == length(ds) <= oldj	
            from = s.colptr.arr[oldj]
            nval = s.colptr.arr[oldj+1] - from
            to = nnz+1
            ncol += 1
            nnz += nval
            if newj != oldj
                copy!(s.rowval.arr, to, s.rowval.arr, from, nval)
                copy!(s.nzval.arr, to, s.nzval.arr, from, nval)
                s.colptr.arr[ncol+1] = nnz+1
                for w in ww; ccopy!(w,newj,w,oldj,1); end
            else 
                @assert to == from
                @assert s.colptr.arr[ncol+1] == nnz+1
            end
        end
    end
    @assert length(ds) == ncol
    s.n = ncol
    resize!(s.colptr, ncol+1)
    resize!(s.rowval, nnz)
    resize!(s.nzval,  nnz)
    for w in ww; resize!(w, csize(w, s.n)); end
    return tuple(s, ww...)
end

_colkey{A<:Array}(s::KUdense{A},j)=sub(s.arr, ntuple(i->(i==ndims(s) ? (j:j) : Colon()), ndims(s))...)

function _colkey{A<:Array}(s::KUsparse{A},j)
    a=s.colptr.arr[j]
    b=s.colptr.arr[j+1]-1
    r=sub(s.rowval.arr, a:b)
    v=sub(s.nzval.arr, a:b)
    (r,v)
end

# Getting columns one at a time is expensive, just copy the whole array
# CudaArray does not support sub, even if it did we would not be able to hash it
# getcol{T}(s::KUdense{CudaArray,T}, j)=(n=clength(s);copy!(Array(T,csize(s,1)), 1, s.arr, (j-1)*n+1, n))

# we need to look at the columns, might as well copy

function uniq!{A<:CudaArray}(s::KUdense{A}, ww::KUdense...)
    ss = cpucopy(s)
    uniq!(ss, ww...)
    cslice!(s, ss, 1:ccount(ss))
    return tuple(s, ww...)
end

function uniq!{A<:CudaArray}(s::KUsparse{A}, ww::KUdense...)
    ss = cpucopy(s)
    uniq!(ss, ww...)
    cslice!(s, ss, 1:ccount(ss))
    return tuple(s, ww...)
end



# TODO: fix array types

    # ds = Dict{Any,Int}()        # dictionary of support vectors
    # ns = 0                      # number of support vectors
    # s0 = spzeros(eltype(s), Int32, size(s,1), ns) # new sv matrix
    # for j=1:size(s,2)
    #     jj = get!(ds, s[:,j], ns+1)
    #     if jj <= ns             # s[:,j] already in s0[:,jj]
    #         @assert ns == length(ds) < j
    #         u[:,jj] += u[:,j]
    #         v[:,jj] += v[:,j]
    #     else                    # s[:,j] to be added to s0
    #         @assert jj == ns+1 == length(ds) <= j
    #         ns = ns+1
    #         hcat!(s0, s, [j], 1)
    #         if jj != j
    #             u[:,jj] = u[:,j]
    #             v[:,jj] = v[:,j]
    #         end
    #     end
    # end
    # @assert ns == length(ds) == size(s0,2)
    # u = size!(u, (size(u,1),ns))
    # v = size!(v, (size(v,1),ns))
    # for f in names(s); s.(f) = s0.(f); end
    # return (s,u,v)

# function uniq!(s::SparseMatrixCSC, u::AbstractArray, v::AbstractArray)
#     ds = Dict{Any,Int}()        # dictionary of support vectors
#     ns = 0                      # number of support vectors
#     s0 = spzeros(eltype(s), Int32, size(s,1), ns) # new sv matrix
#     for j=1:size(s,2)
#         jj = get!(ds, s[:,j], ns+1)
#         if jj <= ns             # s[:,j] already in s0[:,jj]
#             @assert ns == length(ds) < j
#             u[:,jj] += u[:,j]
#             v[:,jj] += v[:,j]
#         else                    # s[:,j] to be added to s0
#             @assert jj == ns+1 == length(ds) <= j
#             ns = ns+1
#             hcat!(s0, s, [j], 1)
#             if jj != j
#                 u[:,jj] = u[:,j]
#                 v[:,jj] = v[:,j]
#             end
#         end
#     end
#     @assert ns == length(ds) == size(s0,2)
#     u = size!(u, (size(u,1),ns))
#     v = size!(v, (size(v,1),ns))
#     for f in names(s); s.(f) = s0.(f); end
#     return (s,u,v)
# end

# function uniq!(ss::CudaSparseMatrixCSC, uu::AbstractCudaArray, vv::AbstractCudaArray)
#     (s,u,v)=map(cpucopy,(ss,uu,vv))
#     (s,u,v)=uniq!(s,u,v)
#     n = size(s,2)
#     uu = size!(uu, (size(u,1),n))
#     vv = size!(vv, (size(v,1),n))
#     copy!(uu, 1, u, 1, size(u,1)*n)
#     copy!(vv, 1, v, 1, size(v,1)*n)
#     (ss.m, ss.n, ss.colptr, ss.rowval, ss.nzval) = (s.m, s.n, gpucopy(s.colptr), gpucopy(s.rowval), gpucopy(s.nzval))
#     return (ss,uu,vv)
# end

# function cslice!{A,T,I}(a::KUsparse{A,T,I}, b::SparseMatrixCSC{T,I}, r::UnitRange)
#     nz = 0; for i in r; nz += b.colptr[i+1]-b.colptr[i]; end
#     a.m = b.m
#     a.n = length(r)
#     resize!(a.nzval, nz)
#     resize!(a.rowval, nz)
#     aptr = Array(I, a.n+1)
#     aptr[1] = a1 = aj = 1
#     for bj in r                 # copy column b[:,bj] to a[:,aj]
#         b1 = b.colptr[bj]
#         nz = b.colptr[bj+1]-b1
#         copy!(a.nzval.arr, a1, b.nzval, b1, nz)
#         copy!(a.rowval.arr, a1, b.rowval, b1, nz)
#         a1 += nz
#         aptr[aj+=1] = a1
#     end
#     @assert aj == a.n+1
#     copy!(a.colptr, aptr)
#     return a
# end
