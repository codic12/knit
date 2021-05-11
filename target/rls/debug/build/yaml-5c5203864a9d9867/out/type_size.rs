use libc::c_int;

#[allow(non_camel_case_types)]
pub type yaml_parser_mem_t = [c_int; 120];
pub fn new_yaml_parser_mem_t() -> yaml_parser_mem_t {
    [0; 120]
}

#[allow(non_camel_case_types)]
pub type yaml_event_data_t = [c_int; 12];
pub fn new_yaml_event_data_t() -> yaml_event_data_t {
    [0; 12]
}

#[allow(non_camel_case_types)]
#[repr(u64)]
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum yaml_event_type_t {
    /** An empty event. */
    YAML_NO_EVENT = 0,

    /** A STREAM-START event. */
    YAML_STREAM_START_EVENT,
    /** A STREAM-END event. */
    YAML_STREAM_END_EVENT,

    /** A DOCUMENT-START event. */
    YAML_DOCUMENT_START_EVENT,
    /** A DOCUMENT-END event. */
    YAML_DOCUMENT_END_EVENT,

    /** An ALIAS event. */
    YAML_ALIAS_EVENT,
    /** A SCALAR event. */
    YAML_SCALAR_EVENT,

    /** A SEQUENCE-START event. */
    YAML_SEQUENCE_START_EVENT,
    /** A SEQUENCE-END event. */
    YAML_SEQUENCE_END_EVENT,

    /** A MAPPING-START event. */
    YAML_MAPPING_START_EVENT,
    /** A MAPPING-END event. */
    YAML_MAPPING_END_EVENT
}

#[allow(non_camel_case_types)]
pub type yaml_parser_input_t = [c_int; 6];

pub fn new_yaml_parser_input_t() -> yaml_parser_input_t {
    [0; 6]
}

#[allow(non_camel_case_types)]
pub type yaml_emitter_output_t = [c_int; 6];

pub fn new_yaml_emitter_output_t() -> yaml_emitter_output_t {
    [0; 6]
}

#[allow(non_camel_case_types)]
pub type yaml_node_data_t = [c_int; 8];

pub fn new_yaml_node_data_t() -> yaml_node_data_t {
    [0; 8]
}

#[cfg(test)]
pub static YAML_PARSER_T_SIZE:usize = 480;
#[cfg(test)]
pub static YAML_EMITTER_T_SIZE:usize = 432;
#[cfg(test)]
pub static YAML_EVENT_T_SIZE:usize = 104;
#[cfg(test)]
pub static YAML_DOCUMENT_T_SIZE:usize = 104;
#[cfg(test)]
pub static YAML_NODE_T_SIZE:usize = 96;
