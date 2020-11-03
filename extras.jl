import Base64.stringmime

struct EmacsBuffer

end


Base.show
# function emlog(x :: Symbol)
#     if (x == :clear)
#         el = JuliaSnail.elexpr((Symbol("julia-snail--log-clear"),))
# #        pipeline(`emacsclient --eval $el`,stdout=devnull) |> run;
#     elseif  (x == :pop)
#         el = JuliaSnail.elexpr((Symbol("julia-snail--log-pop"),))
# #        pipeline(`emacsclient --eval $el`,stdout=devnull) |> run;
#     end
#     JuliaSnail.send_to_client(el)
# end

# function emlog(x:: String,cr=true)
#     x = (cr ? x * "\n" : x)
#     el = JuliaSnail.elexpr((JuliaSnail.Symbol("julia-snail--log-text"),x))
#     JuliaSnail.send_to_client(el)
# end

# function emlog(x:: Matrix)
#     csv = repr("text/csv",x)
#     el = JuliaSnail.elexpr((JuliaSnail.Symbol("julia-snail--log-matrix"),csv))
#     JuliaSnail.send_to_client(el)
# end

# function emlog(x)
#     if showable("image/png", x)
#         imdata =stringmime("image/png",x)
#         el = JuliaSnail.elexpr((JuliaSnail.Symbol("julia-snail--log-image"),imdata,1))
#     else
#         str = repr("text/plain",x) * "\n"
#         el = JuliaSnail.elexpr((JuliaSnail.Symbol("julia-snail--log-text"),str))
#     end
#     JuliaSnail.send_to_client(el)
# end





# macro emlog(exs...)
#     blk = Expr(:block)
#     for ex in exs
#         push!(blk.args,quote
#             res = $ex
#             if (any(map((v) -> isa(res,v),[Number,String,Char,Vector])))
#                 cr = false
#             else
#                 cr = true
#             end
#             emlog($(sprint(Base.show_unquoted,ex)*" = "),cr)
#             emlog($ex)
#               end)
#     end
#     return blk
# end

