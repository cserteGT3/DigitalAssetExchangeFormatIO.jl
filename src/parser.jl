function load(file::File{format"DAE"}; cfg=DAEParserConfig())
    with_logger(cfg.logger) do
        f = open(file)
        doc = parse_string(read(stream(f), String))
        xml = root(doc)
        @assert name(xml) == "COLLADA"
        library_effects = merge_dicts(read_library_effects.(get_elements_by_tagname(xml, "library_effects"))...)
        library_materials = merge_dicts(read_library_materials.(get_elements_by_tagname(xml, "library_materials"))...)
        library_geometries = merge_dicts(read_library_geometries.(get_elements_by_tagname(xml, "library_geometries"))...)
        library_visual_scenes = merge_dicts(read_library_visual_scenes.(get_elements_by_tagname(xml, "library_visual_scenes"))...)
        return DAEScene(library_effects, library_materials, library_geometries, library_visual_scenes)
    end
end

#################################################
# Library effects
#################################################

function read_library_effects(library_effects::XMLElement)
    effects = get_elements_by_tagname(library_effects, "effect")
    Dict(
        attribute(effect, "id")=>read_effect(effect)
        for effect in effects
    )
end

function read_effect(effect::XMLElement)
    warn_unsupported_element.((effect,), ("profile_BRIDGE", "profile_CG", "profile_GLES", "profile_GLES2", "profile_GLSL"))
    profile_COMMON = find_element(effect, "profile_COMMON")
    technique = find_unique_element(profile_COMMON, "technique")
    read_technique(technique)
end

function read_technique(technique::XMLElement)
    warn_unsupported_element.((technique,), ("cosntant", "blinn"))

    if ~isnothing(find_element(technique, "lambert"))
        read_lambert(find_unique_element(technique, "lambert"))
    elseif ~isnothing(find_element(technique, "phong"))
        read_phong(find_unique_element(technique, "phong"))
    else
        error("Expected either lambert or phong")
    end
end

function read_phong(phong::XMLElement)
    PhongShadingParams(
        read_color(find_element(phong, "emission")),
        read_color(find_element(phong, "ambient")),
        read_color(find_element(phong, "diffuse")),
        read_color(find_element(phong, "specular")),
        read_float(find_element(phong, "shininess")),
        read_color(find_element(phong, "reflective")),
        read_float(find_element(phong, "reflectivity")),
        read_color(find_element(phong, "transparent")),
        read_float(find_element(phong, "transparency"))
    )
end

function read_lambert(lambert::XMLElement)
    LambertShadingParams(
        read_color(find_element(lambert, "emission")),
        read_color(find_element(lambert, "ambient")),
        read_color(find_element(lambert, "diffuse")),
        read_color(find_element(lambert, "reflective")),
        read_float(find_element(lambert, "reflectivity")),
        read_color(find_element(lambert, "transparent")),
        read_float(find_element(lambert, "transparency")),
        read_float(find_element(lambert, "index_of_refraction"))
    )
end

read_color(::Nothing) = nothing

function read_color(color::XMLElement)
    r, g, b, a = split(content(color))
    RGBA(parse(Float32, r), parse(Float32, g), parse(Float32, b), parse(Float32, a))

end

read_float(::Nothing) = nothing

function read_float(float::XMLElement)
    parse(Float32, content(float))
end

#################################################
# Library materials
#################################################

function read_library_materials(library_materials::XMLElement)
    materials = get_elements_by_tagname(library_materials, "material")
    Dict(
        attribute(material, "id")=>read_material(material)
        for material in materials
    )
end

function read_material(material::XMLElement)
    instance_effect = only(get_elements_by_tagname(material, "instance_effect"))
    url = attribute(instance_effect, "url")
    @assert startswith(url, "#")
    url[2:end]
end

#################################################
# Library geometries
#################################################

function read_library_geometries(library_geometries::XMLElement)
    geometries = get_elements_by_tagname(library_geometries, "geometry")
    Dict(
        attribute(geometry, "id")=>read_geometry(geometry)
        for geometry in geometries
    )
end

function read_geometry(geometry::XMLElement)
    mesh_nodes = Iterators.filter(child_elements(geometry)) do node
        name(node) == "mesh"
    end
    meshes = [read_mesh(node) for node in mesh_nodes]
    only(meshes) # We only support one mesh per geometry
end

function warn_unsupported_element(node::XMLElement, element_name)
    isnothing(find_element(node, element_name)) || @warn("$(element_name) is not supported")
end

function read_mesh(mesh::XMLElement)
    positions = read_positions(mesh)

    warn_unsupported_element.((mesh,), ("lines", "linestrips", "polygons", "trifans", "tristrips"))
    
    polylist = find_element(mesh, "polylist")
    triangles = find_element(mesh, "triangles")
    
    num_elements = sum(!isnothing((polylist, triangles)))
    @assert num_elements == 1 "Must have one of polylist or triangles, got $num_elements"

    if !isnothing(polylist)
        source = polylist
        data = read_polylist(polylist)
    elseif !isnothing(triangles)
        source = triangles
        data = read_triangles(triangles)
    else
        error("Should not happen")
    end
    
    (; name, material, vectors) = data    
    normals = read_normals(mesh, source)
    face_vertex_indices = vectors["VERTEX"]
    face_normal_indices = vectors["NORMAL"]
    (;
        name = name,
        material = material,
        mesh = to_geometrybasics_mesh(positions, normals, face_vertex_indices, face_normal_indices)
    )
end

function to_geometrybasics_mesh(positions, normals, face_vertex_indices, face_normal_indices)
    @assert length(face_vertex_indices) == length(face_normal_indices)
    face_type = eltype(face_vertex_indices)
    point_type = Point{3, Float64}
    # element_type = GeometryBasics.Ngon{3, Float64, 3, point_type}
    per_face_normals = GeometryBasics.FaceView{point_type, Vector{point_type}, Vector{face_type}}(normals, face_normal_indices)
    # per_face_normals = FaceView{element_type, point_type, face_type, Vector{point_type}, Vector{face_type}}(normals, face_normal_indices)
    Mesh(positions, face_vertex_indices; normal=per_face_normals)
end

function read_polylist(polylist::XMLElement)
    V = NgonFace{3, OffsetInteger{-1, Int32}}
    name = attribute(polylist, "name")
    count = parse(Int, attribute(polylist, "count", required=true))
    material = attribute(polylist, "material")
    inputs = get_elements_by_tagname(polylist, "input")
    offsets = parse.(Int, attribute.(inputs, "offset"))
    width = maximum(offsets) + 1
    vectors = [Vector{V}(undef, count) for i in inputs]
    i = 1
    for values in partition(split(content(find_element(polylist, "p")), ' '), 3 * width)
        for j in 1:length(vectors)
            offset = offsets[j]
            vectors[j][i] = V(ntuple(k -> 1 + parse(Int32, values[(k - 1) * width + offset + 1]), Val(3)))
        end
        i += 1
    end
    @assert i == length(vectors[1]) + 1 == length(vectors[2]) + 1
    (;
        name = name,
        material=material,
        vectors = Dict{String, Vector{V}}(zip(attribute.(inputs, "semantic"), vectors))
    )
end

function read_triangles(triangles::XMLElement)
    V = NgonFace{3, OffsetInteger{-1, Int32}}
    name = attribute(triangles, "name")
    count = parse(Int, attribute(triangles, "count"; required=true))
    material = attribute(triangles, "material")
    inputs = get_elements_by_tagname(triangles, "input")
    num_inputs = length(inputs)
    offsets = parse.(Int, attribute.(inputs, "offset"; required=true))
    semantics = attribute.(inputs, "semantic"; required=true)
    width = maximum(offsets) + 1 # Maximum offset + 1, number of indices per vertex
    
    # Read p
    p = [Vector{Int}(undef, 3 * width) for i in 1:count]
    for (i, values) in enumerate(partition(split(content(find_element(triangles, "p")), ' '), 3 * width))
        for j = 1:(3*width)
            p[i][j] = parse(Int, values[j])
        end
    end
    # Process p into vector for each input
    vectors = [Vector{V}(undef, count) for i in inputs]
    for j in 1:num_inputs
        offset = offsets[j]
        for i in 1:count
            vectors[j][i] = V(ntuple(k -> 1 + p[i][(k - 1) * width + offset + 1], Val(3)))
        end
    end 
    (;
        name = name,
        material=material,
        vectors = Dict{String, Vector{V}}(zip(semantics, vectors))
    )
end


#################################################
# Library visual scenes
#################################################

function read_library_visual_scenes(library_visual_scenes::XMLElement)
    scenes = get_elements_by_tagname(library_visual_scenes, "visual_scene")
    @assert length(scenes) >= 1
    mesh_url_to_matrix_dicts = map(read_visual_scene, scenes)
    Dict(Iterators.flatten(mesh_url_to_matrix_dicts))
end

function read_visual_scene(visual_scene::XMLElement)
    nodes = get_elements_by_tagname(visual_scene, "node")
    @assert length(nodes) >= 1
    Dict(Iterators.flatten(map(read_visual_scene_node, nodes)))
end

function read_visual_scene_node(node::XMLElement)    
    sub_nodes = get_elements_by_tagname(node, "node")
    @assert isempty(sub_nodes) "Recursive nodes in visual scenes are not supported"
    transform::Matrix = read_transformation_elements(node)
    instance_geometry = get_elements_by_tagname(node, "instance_geometry")
    ret = Dict(get_url(geometry)=>transform for geometry in instance_geometry)
end

function read_transformation_elements(node::XMLElement)
    matrix = [
        1.0  0.0  0.0  0.0;
        0.0  1.0  0.0  0.0;
        0.0  0.0  1.0  0.0;
        0.0  0.0  0.0  1.0
    ]
    for element in child_elements(node)
        if name(element) == "matrix"
            matrix = read_matrix(element) * matrix
        elseif name(element) == "rotate"
            matrix = read_rotate(element) * matrix
        elseif name(element) == "scale"
            matrix = read_scale(element) * matrix
        elseif name(element) == "skew"
            matrix = read_skew(element) * matrix
        elseif name(element) == "translate"
            matrix = read_translate(element) * matrix
        elseif name(element) == "lookat"
            @warn "Ignoring 'lookat' transformation, may cause incorrect results"
        end
    end
    matrix
end

function read_matrix(node; size=(4, 4))
    vals = split(content(node), " ")
    @assert length(vals) == size[1] * size[2]
    matrix = zeros(Float32, size)
    for i in 1:size[1]
        for j in 1:size[2]
            matrix[i, j] = parse(Float32, vals[(i - 1) * 4 + j])
        end
    end
    matrix
end

function read_rotate(node::XMLElement)
    vals = split(content(node), " ")
    @assert length(vals) == 4
    axis = Vec3f(parse(Float32, vals[1]), parse(Float32, vals[2]), parse(Float32, vals[3]))
    @assert sqrt(axis' * axis) ≈ 1.0
    angle = parse(Float32, vals[4])
    # Convert to matrix, https://www.euclideanspace.com/maths/geometry/rotations/conversions/angleToMatrix/index.htm
    c = cos(angle)
    s = sin(angle)
    t = 1 - c
    x = axis[1]
    y = axis[2]
    z = axis[3]
    [
        t*x*x + c       t*x*y - z*s     t*x*z + y*s  0.0;
        t*x*y + z*s     t*y*y + c       t*y*z - x*s  0.0;
        t*x*z - y*s     t*y*z + x*s     t*z*z + c    0.0;
        0.0             0.0             0.0          1.0
    ]
end

function read_scale(node::XMLElement)
    vals = split(content(node), " ")
    @assert length(vals) == 3
    x = parse(Float32, vals[1])
    y = parse(Float32, vals[2])
    z = parse(Float32, vals[3])
    [
        x       0.0     0.0     0.0;
        0.0     y       0.0     0.0;
        0.0     0.0     z       0.0;
        0.0     0.0     0.0     1.0
    ]
end

function read_skew(node::XMLElement)
    error("Skew transformation not supported by this parser")
end

function read_translate(node::XMLElement)
    vals = split(content(node), " ")
    @assert length(vals) == 3
    x = parse(Float32, vals[1])
    y = parse(Float32, vals[2])
    z = parse(Float32, vals[3])
    [
        1.0  0.0  0.0 x;
        0.0  1.0  0.0 y;
        0.0  0.0  1.0 z;
        0.0  0.0  0.0 1.0
    ]
end

#################################################
# Other
#################################################

function find_unique_element(node::XMLElement, element_name::AbstractString)
    elements = get_elements_by_tagname(node, element_name)
    @assert length(elements) == 1 "Expected one $element_name, got $(length(elements))"
    only(elements)
end

function merge_dicts(d::AbstractDict, others...)
    throw_err = (a, b) -> error("Duplicate key: $a, $b")
    mergewith(throw_err, d, others...)
end

function find_source(mesh::XMLElement, source_label::AbstractString)
    @assert source_label[1] == '#'
    only(filter(get_elements_by_tagname(mesh, "source")) do source
        attribute(source, "id") == source_label[2:end]
    end)
end

function _read_source(T, V, N, source)
    array = find_element(source, "float_array")
    result = Vector{V}(undef,
        convert(Int, parse(Int, attribute(array, "count")) / N))
    i = 1
    for values in partition(split(content(array), ' '), N)
        result[i] = let values = values
            V(ntuple(i -> parse(T, values[i]), Val(N)))
        end
        i += 1
    end
    @assert i == length(result) + 1
    result
end

function read_source(::Type{V}, source::XMLElement) where {T, V <: AbstractVector{T}}
    N = length(V) # length not defined on Normal, but it is always 3
    _read_source(T, V, N, source) 
end

function read_source(::Type{M}, source::XMLElement) where {T, V<:AbstractVector{T}, M<:Normal{V}}
    N = length(V)
    @assert N == 3
    _read_source(T, V, N, source)
end

function read_positions(mesh::XMLElement)
    vertices = find_element(mesh, "vertices")
    # Read the mesh positions
    position_input = only(Iterators.filter(child_elements(vertices)) do input
        attribute(input, "semantic") == "POSITION"
    end)
    position_source = find_source(mesh, attribute(position_input, "source"))
    read_source(Point{3, Float32}, position_source)
end

function read_normals(mesh::XMLElement, geometry_primitive::XMLElement)
    normal_input = only(Iterators.filter(child_elements(geometry_primitive)) do input
        attribute(input, "semantic") == "NORMAL"
    end)
    normal_source = find_source(mesh, attribute(normal_input, "source"))
    normals = read_source(Normal{Vec3f}, normal_source)
end

function get_normals_in_vertex_order(mesh, positions, geometry_primitive, data)
    normals = read_normals(mesh, geometry_primitive)
    normals_in_vertex_order = Vector{Vec3f}(undef, length(positions))
    face_normals = data["NORMAL"]
    for (fv, fn) in zip(data["VERTEX"], data["NORMAL"])
        for i in 1:3
            normals_in_vertex_order[fv[i]] = normals[fn[i]]
        end
    end
    normals_in_vertex_order
end

function get_url(node)
    url = attribute(node, "url")
    @assert startswith(url, "#")
    url[2:end]
end




