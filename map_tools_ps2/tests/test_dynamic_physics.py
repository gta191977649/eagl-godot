import struct
from dataclasses import replace
import xml.etree.ElementTree as ET

from map_tools_ps2 import dynamic_physics
from map_tools_ps2.model import Scene, SceneryInstance
from map_tools_ps2.source_physics import SourcePhysics, SourcePhysicsTemplate, SourcePhysicsBinding
from map_tools_ps2.mta_scene import build_mta_scene, MtaModel
from map_tools_ps2.managed_export import geometry_key, definition_key
from map_tools_ps2.mta_export import _write_resource_xml
from map_tools_ps2.textures import TextureLibrary
from test_mta_export import _triangle_object, _matrix


def template(threshold=0.2, key=1):
    raw=bytearray(224)
    struct.pack_into('<I',raw,0x70,key)
    struct.pack_into('<f',raw,0xb4,threshold)
    struct.pack_into('<f',raw,0xbc,0.1)
    return SourcePhysicsTemplate(key,'source',0,bytes(raw),0.005,(0,)*16,(1,2,3),0,
        ((0,0,0),(4,0,0),(0,4,0),(0,0,4)),((0,2,1),(0,1,3),(0,3,2),(1,2,3)))


def test_dynamic_large_prop_stays_one_body_and_has_xml_physics(tmp_path):
    obj=_triangle_object('RD_DYNAMIC_SOURCE',10)
    instance=SceneryInstance(0,obj.name,_matrix(scale=(10,10,10)),100,0)
    source=Scene(objects=[obj],scenery_instances=[instance],source_physics=SourcePhysics(
        (template(),),(SourcePhysicsBinding(0,1,1,0,100,(1,0,0)),)))
    scene=build_mta_scene(source,TextureLibrary({}),track_id=25,resource_name='test')
    dynamic=[m for m in scene.models if m.physics]
    assert len(dynamic)==1
    model=dynamic[0]
    assert model.kind=='prop' and model.collision_faces and not model.is_lod
    assert all(p.element_type=='object' and not p.lod_parent for p in scene.placements if p.model_id==model.model_id)
    attrs=dynamic_physics.definition_attributes(model)
    placement_attrs=dynamic_physics.placement_attributes(model)
    assert attrs['physicsRoot']=='1233'
    assert attrs['simulated']=='true' and attrs['frozen']=='false'
    assert attrs['breakable']=='true'
    assert attrs['mass']=='30' and attrs['turnMass']=='50'
    assert attrs['airResistance']=='0.99' and attrs['buoyancy']=='50'
    assert placement_attrs=={**attrs, 'dynamic':'true'}
    _write_resource_xml(scene,tmp_path,'test',[],(0,0,0))
    definition=next(e for p in tmp_path.rglob('*.definition') for e in ET.parse(p).getroot() if e.get('id')==model.model_id)
    placement=next(e for p in tmp_path.rglob('*.map') for e in ET.parse(p).getroot() if e.get('id')==model.model_id)
    for k,v in attrs.items():assert definition.get(k)==v and placement.get(k)==v
    assert placement.get('dynamic')=='true' and definition.get('dynamic') is None


def test_geometry_shared_but_physics_definitions_distinct():
    a=MtaModel('a','a','prop','zone',(2,3,4));b=replace(a,model_id='b')
    dynamic_physics.configure(a,template(),(2,2,2),0)
    dynamic_physics.configure(b,template(0),(2,2,2),0)
    assert geometry_key(a)==geometry_key(b)
    assert dynamic_physics.definition_physics_key(a)!=dynamic_physics.definition_physics_key(b)
    assert definition_key(a)!=definition_key(b)
    assert a.collision_vertices[0]==(-2,-3,-4)
    assert dynamic_physics.definition_attributes(a)['centerOfMass']=='0,1,2'
    c=replace(a,model_id='c')
    dynamic_physics.configure(c,template(key=2),(2,2,2),0)
    assert dynamic_physics.definition_physics_key(c)==dynamic_physics.definition_physics_key(a)
    assert definition_key(c)==definition_key(a)


def test_dynamic_collision_primitive_uses_source_bounds_and_minimum_thickness():
    model=MtaModel('sign','sign','prop','zone',(0,0,0))
    model.physics={'source_signature':'x'}
    model.collision_vertices=[(-2,-0.01,-1),(2,0.01,1)]
    assert dynamic_physics.collision_primitive(model)=={
        'type':'box','center':[0.0,0.0,0.0],
        'half_extents':[2.0,0.05,1.0],'surface':0,
    }

    model.collision_vertices=[(-1,-0.9,-1),(1,0.9,1)]
    assert dynamic_physics.collision_primitive(model)=={
        'type':'sphere','center':[0.0,0.0,0.0],'radius':1.0,'surface':0,
    }


def test_different_source_physics_same_visual_placement_not_combined():
    obj=_triangle_object('PROP',10)
    source=Scene(objects=[obj],scenery_instances=[
        SceneryInstance(0,obj.name,_matrix(position=(x,0,0)),100,i) for i,x in enumerate((0,20))],
        source_physics=SourcePhysics((template(),template(0,2)),(
            SourcePhysicsBinding(0,1,1,0,100,(1,0,0)),SourcePhysicsBinding(8,2,1,1,100,(1,0,0)))))
    scene=build_mta_scene(source,TextureLibrary({}),track_id=25,resource_name='test')
    assert len([m for m in scene.models if m.physics])==2
    assert len(scene.placements)==2
