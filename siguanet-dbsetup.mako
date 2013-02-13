## -*- coding: utf-8 -*-

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

SET search_path = public, pg_catalog;

CREATE TABLE puestos (
    cod_puesto character varying(10) NOT NULL,
    txt_puesto character varying(40) NOT NULL,
    pdi_pas character varying(7) DEFAULT 'CAMBIAR'::character varying NOT NULL,
    investigador boolean,
    etic smallint,
    CONSTRAINT puestos_pdi_pas CHECK ((((((pdi_pas)::text = 'PDI'::text) OR ((pdi_pas)::text = 'PAS'::text)) OR ((pdi_pas)::text = 'OTROS'::text)) OR ((pdi_pas)::text = 'CAMBIAR'::text)))
);

CREATE TABLE todaspersonas (
    nif character varying(9) NOT NULL,
    codigo character varying(9) NOT NULL,
    cod_puesto character varying(10) NOT NULL,
    cod_depto character varying(10),
    usuario text,
    fecha date
);

CREATE TABLE departamentossigua (
    cod_dpto_sigua character varying(10) NOT NULL,
    txt_dpto_sigua character varying(70),
    cod_centro character varying(10) NOT NULL
);

CREATE TABLE todasestancias (
    codigo character varying(9) NOT NULL,
    coddpto character varying(10) NOT NULL,
    actividad smallint NOT NULL,
    usuario text,
    fecha date,
    denominaci character varying(100),
    observacio character varying(100)
);

ALTER TABLE todasestancias ADD COLUMN geometria geometry(MultiPolygon, ${referencia_espacial});

CREATE TABLE edificios (
    cod_zona character varying(2) NOT NULL,
    cod_edificio character varying(2) NOT NULL,
    txt_edificio character varying(70) NOT NULL,
    txt_edificio_web character varying(70),
    visibilidad boolean DEFAULT true,
    rotacion numeric(10,10),
    traslacion numeric(10,10)
);

% for planta in plantas:

ALTER TABLE edificios ADD COLUMN ${planta} boolean;

% endfor

COMMENT ON TABLE edificios IS 'Listado de edificios de todos los campus o zonas. También hay información sobre qué plantas tiene (true o false)';

COMMENT ON COLUMN edificios.visibilidad IS 'Columna que indica que un edificio es visible o n';

COMMENT ON COLUMN edificios.rotacion IS 'Angulo de rotación de los edificios';

CREATE FUNCTION comprueba_actividad() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
        IF new.codigo  
            NOT IN (SELECT codigo FROM todasestancias WHERE actividad IN (SELECT codactividad as actividad FROM actividades WHERE personal = true)) THEN
            RAISE EXCEPTION 'La persona con NIF % que intenta insertar en % tiene una actividad que no es apropiada.',NEW.nif, NEW.codigo;
        END IF;
        
        RETURN NEW;
    END;
$$;

CREATE FUNCTION comprueba_borrar_estancia_con_personal(character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $_$
    BEGIN
	   RETURN (SELECT count(nif) FROM todaspersonas WHERE codigo = $1);
    END;
$_$;

CREATE FUNCTION comprueba_estancia() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
        IF new.codigo  NOT IN ( SELECT todasestancias.codigo FROM todasestancias) THEN
            RAISE EXCEPTION 'NO EXISTE LA ESTANCIA % EN LA TABLA ESTANCIAS', NEW.codigo;
            END IF;
            RETURN NEW;
    END;
$$;

CREATE FUNCTION comprueba_personal_estancia() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
	DECLARE personas integer;
    BEGIN
	
	personas = comprueba_borrar_estancia_con_personal(OLD.codigo) ;
         IF (comprueba_borrar_estancia_con_personal(OLD.codigo) > 0) THEN
            RAISE EXCEPTION 'La estancia % no se puede borrar, ya que hay % personas  en ella',OLD.codigo,personas;
	 END IF;      
       RETURN OLD;
    END;
$$;

CREATE FUNCTION comprueba_superficie() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
        IF new.codigo != '0000PB997'
            AND new.codigo
            IN (SELECT codigo FROM todasestancias WHERE st_area(geometria) < 6) THEN
            RAISE EXCEPTION 'ERROR FATAL. Intentas insertar una persona con NIF % en una estancia, la %, con una superficie de menos de 6 metros cuadrados. 
¿Quieres emparedarlo?',NEW.nif, NEW.codigo;
        END IF;
        
        RETURN NEW;
    END;
$$;

CREATE FUNCTION listar_plantas(zona character varying, edificio character varying) RETURNS character varying[]
    LANGUAGE plpgsql
    AS $$
    DECLARE
        query CURSOR FOR SELECT column_name, data_type FROM information_schema.columns 
                          WHERE table_schema = 'public' AND table_name = 'edificios';
        floors varchar[] := ARRAY[]::varchar[];
        floor_exists boolean;
    BEGIN
        FOR r IN query loop
         IF r.data_type = 'boolean' THEN
          IF r.column_name ~ '^p[b|s]$' OR r.column_name ~ '^[p|s][1-9]+$' THEN
           EXECUTE 'SELECT ' || quote_ident(r.column_name) || ' FROM edificios WHERE cod_zona = $1 AND cod_edificio = $2' 
                   INTO floor_exists USING zona, edificio;
           IF floor_exists THEN
            floors := floors || r.column_name::varchar;
           END IF;
          END IF;
         END IF;
        END LOOP;
        RETURN floors;
    END;
 $$;

CREATE FUNCTION comprueba_texto_estancia() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE 
        zona character varying;
        edificio character varying;
        planta character varying;
        estancia character varying;
    BEGIN
        IF char_length(NEW.codigo) < 9 THEN
            RAISE EXCEPTION 'La estancia % tiene menos de 9 caracteres',NEW.codigo;
        END IF;

        zona := substring(NEW.codigo from 1 for 2);
        edificio := substring(NEW.codigo from 3 for 2);
        planta := substring(NEW.codigo from 5 for 2);
        estancia := substring(NEW.codigo from 7 for 3);

	IF NOT EXISTS(SELECT 1 FROM zonas WHERE cod_zona = zona) THEN
           RAISE EXCEPTION 'La estancia % que intenta insertar tiene un campus que NO EXISTE.',NEW.codigo;
        END IF;

        IF NOT EXISTS(SELECT 1 FROM edificios WHERE cod_zona = zona AND cod_edificio = edificio) THEN
            RAISE EXCEPTION 'La estancia con código % tiene un codigo de edificio que NO EXISTE.',NEW.codigo;
        END IF;
        
        IF lower('sig'||planta) != lower(TG_TABLE_NAME::character varying) THEN
            RAISE EXCEPTION 'La estancia con codigo  % tiene un codigo de planta no admitido en la tabla %.',NEW.codigo, TG_TABLE_NAME::character varying;
        END IF;

        IF estancia !~ '^[0-9]{3}$' THEN
            RAISE EXCEPTION 'La estancia con codigo  % tiene un número de estancia no admitido.';
        END IF;

        RETURN NEW;
    END;
$$;

CREATE FUNCTION inserta_personalexternos() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
	t timestamp;
	usr varchar;
    BEGIN
	t := 'now';
	usr := current_user;
 
        IF new.nif  NOT IN ( SELECT personal.nif FROM personal) 
        THEN
            INSERT INTO personal (nif, apellido1, apellido2, nombre) 
            VALUES (new.nif, new.apellido1, new.apellido2, new.nombre);
         END IF;

         INSERT INTO todaspersonas (nif, codigo, cod_puesto, cod_depto, usuario, fecha) 
         VALUES (new.nif, new.codigo, new.cod_puesto, new.cod_dpto_sigua, usr, t );
         RETURN NEW; 
    END;
$$;

CREATE TABLE actividades (
    codactividad smallint NOT NULL,
    txt_actividad character varying(40) NOT NULL,
    activresum character varying(15) NOT NULL,
    txt_actividad_val character varying(40),
    util boolean DEFAULT true,
    crue character varying(50),
    u21 character varying(10),
    personal boolean DEFAULT false,
    superficie_computable boolean DEFAULT true,
    inventariable boolean DEFAULT false,
    carto character varying(50)
);

COMMENT ON TABLE actividades IS 'Actividades que pueden ser desempeñadas en una estancia';

COMMENT ON COLUMN actividades.util IS 'indica si la actividad computa como una superficie útil (true) o no (false)';

COMMENT ON COLUMN actividades.personal IS 'True =  la actividad es propicia para insertar personal (ej. despacho)
False = en estos usos no puede haber personal (ej: aseos)';

COMMENT ON COLUMN actividades.carto IS 'Copia de la columna activresum, pero sin acentos. Se utiliza sólo para crear clases con mapserver/mapscript';

CREATE TABLE departamentos (
    cod_dpto character varying(10) NOT NULL,
    txt_dpto character varying(70) NOT NULL,
    sigla_dpto character varying(20),
    txt_dpto_val character varying(70),
    cod_centro character varying(10) DEFAULT '1B00'::character varying NOT NULL
);

COMMENT ON TABLE departamentos IS 'Tabla de departamentos docentes. Esta tabla tiene reglas a través de las que se controla la actualización de la tabla departamentossigua.';

COMMENT ON COLUMN departamentos.sigla_dpto IS 'Siglas del departamento.';

COMMENT ON COLUMN departamentos.txt_dpto_val IS 'Texto del dpto en idioma alternativo';

CREATE TABLE unidades (
    cod_unidad character varying(10) NOT NULL,
    txt_unidad character varying(70),
    cod_centro character varying(10)
);

CREATE TABLE zonas (
    cod_zona character varying(2) NOT NULL,
    txt_zona character varying(60) NOT NULL
);

CREATE TABLE becarios (
    nif character varying(9) NOT NULL,
    codigo character varying(9) NOT NULL,
    apellido1 character varying(30) NOT NULL,
    apellido2 character varying(30),
    nombre character varying(30) NOT NULL,
    cod_depto_centro_subunidad character varying(10) NOT NULL,
    cod_puesto character varying(10) DEFAULT 'SP011'::character varying NOT NULL
);

COMMENT ON TABLE becarios IS 'Becarios de organismos públicos autonómicos o estatales.';

COMMENT ON COLUMN becarios.codigo IS 'Código SIGUA de la estancia donde se encuentra el individuo';

CREATE TABLE personal (
    nif character varying(9) NOT NULL,
    apellido1 character varying(30) NOT NULL,
    apellido2 character varying(30),
    nombre character varying(30) NOT NULL,
    perfil character varying(25)
);

COMMENT ON TABLE personal IS 'Datos personales del personal de la universidad';

CREATE TABLE personalexternos (
    nif character varying(9) NOT NULL,
    apellido1 character varying(30) NOT NULL,
    apellido2 character varying(30),
    nombre character varying(30) NOT NULL,
    codigo character varying(9) NOT NULL,
    cod_puesto character varying(10) NOT NULL,
    cod_dpto_sigua character varying(10) NOT NULL,
    CONSTRAINT cod_puesto CHECK (((((((cod_puesto)::text = 'TÉCNICO'::text) OR ((cod_puesto)::text = 'ADMINISTRA'::text)) OR ((cod_puesto)::text = 'DOCENTE'::text)) OR ((cod_puesto)::text = 'DIRECCIÓN'::text)) OR ((cod_puesto)::text = 'BECARIOS'::text)))
);

COMMENT ON TABLE personalexternos IS 'Tabla con el personal externo (ni contratados ni funcionarios de la universidad.';

COMMENT ON COLUMN personalexternos.nif IS 'NIF del personal';

COMMENT ON COLUMN personalexternos.codigo IS 'Código SIGUA de la estancia donde se encuentra el individuo';

CREATE TABLE personalpas (
    nif character varying(9) NOT NULL,
    codigo character varying(9) NOT NULL,
    cod_puesto character varying(10) NOT NULL,
    cod_unidad character varying(10) NOT NULL,
    cod_sub character varying(10) NOT NULL,
    cod_centro character varying(10) NOT NULL
);

COMMENT ON TABLE personalpas IS 'Tabla con el personal de tipo PAS.';

COMMENT ON COLUMN personalpas.nif IS 'NIF del personal';

COMMENT ON COLUMN personalpas.codigo IS 'Código SIGUA de la estancia donde se encuentra el individuo';

CREATE TABLE personalpdi (
    nif character varying(9) NOT NULL,
    codigo character varying(9) NOT NULL,
    cod_puesto character varying(10) NOT NULL,
    cod_centro character varying(10) NOT NULL,
    cod_depto character varying(10) NOT NULL
);

COMMENT ON TABLE personalpdi IS 'Personal docente';

COMMENT ON COLUMN personalpdi.codigo IS 'Código SIGUA de la estancia donde se encuentra el individuo';

CREATE TABLE personalpdi_cargos (
    nif character varying(9) NOT NULL,
    codigo character varying(9) NOT NULL,
    cod_cargo character varying(10) NOT NULL
);

COMMENT ON TABLE personalpdi_cargos IS 'Personal docente con cargos';

COMMENT ON COLUMN personalpdi_cargos.codigo IS 'Código SIGUA de la estancia donde se encuentra el individuo';

CREATE TABLE cargos (
    cod_cargo character varying(10) NOT NULL,
    txt_cargo character varying(100) NOT NULL
);

COMMENT ON TABLE cargos IS 'Listado de cargos de personal. Tiene como clave cod_cargo.';

CREATE TABLE centros (
    cod_centro character varying(10) NOT NULL,
    txt_centro character varying(70) NOT NULL
);

% for planta in plantas:
CREATE TABLE ${planta} (
    gid integer NOT NULL,
    codigo character varying(9) NOT NULL,
    coddpto character varying(10) NOT NULL,
    actividad smallint NOT NULL,
    denominaci character varying(100),
    observacio character varying(100),
    geometria geometry(MultiPolygon,${referencia_espacial})
);

% endfor

CREATE TABLE subunidades (
    cod_sub character varying(10) NOT NULL,
    txt_sub character varying(40) NOT NULL
);

CREATE TABLE cargos_dpto (
    coddpto character varying(10) NOT NULL,
    cod_cargo character varying(10) NOT NULL,
    tipo character varying(50)
);

COMMENT ON TABLE cargos_dpto IS 'Relación de cargos con departamentos SIGUA.';

CREATE TABLE personalpas_cargos (
    nif character varying(9) NOT NULL,
    codigo character varying(9) NOT NULL,
    cod_cargo character varying(10) NOT NULL
);

% for planta in plantas:
CREATE SEQUENCE ${planta}_gid_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE ${planta}_gid_seq OWNED BY ${planta}.gid;

% endfor

% for planta in plantas:
ALTER TABLE ONLY ${planta} ALTER COLUMN gid SET DEFAULT nextval('${planta}_gid_seq'::regclass);

% endfor

ALTER TABLE ONLY actividades
    ADD CONSTRAINT actividades_pkey PRIMARY KEY (codactividad);

ALTER TABLE ONLY cargos_dpto
    ADD CONSTRAINT cargos_dpto_pkey PRIMARY KEY (cod_cargo);

ALTER TABLE ONLY cargos
    ADD CONSTRAINT cargos_pkey PRIMARY KEY (cod_cargo);

ALTER TABLE ONLY centros
    ADD CONSTRAINT centros_pkey PRIMARY KEY (cod_centro);

ALTER TABLE ONLY becarios
    ADD CONSTRAINT clave_becarios PRIMARY KEY (nif, codigo);

ALTER TABLE ONLY personalpas_cargos
    ADD CONSTRAINT clave_personalpascargos PRIMARY KEY (nif, codigo, cod_cargo);

ALTER TABLE ONLY personalpdi_cargos
    ADD CONSTRAINT clave_personalpdicargo PRIMARY KEY (nif, codigo, cod_cargo);

ALTER TABLE ONLY departamentos
    ADD CONSTRAINT cod_depto_departamentos PRIMARY KEY (cod_dpto);

ALTER TABLE ONLY departamentossigua
    ADD CONSTRAINT departamentossigua_pkey PRIMARY KEY (cod_dpto_sigua);

ALTER TABLE ONLY edificios
    ADD CONSTRAINT edificios_pkey PRIMARY KEY (cod_zona, cod_edificio);

ALTER TABLE ONLY personalexternos
    ADD CONSTRAINT nifcodigo_key PRIMARY KEY (nif, codigo);

ALTER TABLE ONLY personal
    ADD CONSTRAINT personal_pkey PRIMARY KEY (nif);

ALTER TABLE ONLY personalpas
    ADD CONSTRAINT personalpas_pkey PRIMARY KEY (nif, codigo, cod_puesto, cod_unidad, cod_sub, cod_centro);

ALTER TABLE ONLY personalpdi
    ADD CONSTRAINT personalpdi_pkey PRIMARY KEY (nif, codigo, cod_puesto, cod_centro, cod_depto);

ALTER TABLE ONLY puestos
    ADD CONSTRAINT puestos_pkey PRIMARY KEY (cod_puesto);

% for planta in plantas:
ALTER TABLE ONLY ${planta}
    ADD CONSTRAINT ${planta}_pkey PRIMARY KEY (gid);

% endfor

ALTER TABLE ONLY subunidades
    ADD CONSTRAINT subunidades_pkey PRIMARY KEY (cod_sub);

ALTER TABLE ONLY unidades
    ADD CONSTRAINT unidades_pkey PRIMARY KEY (cod_unidad);

ALTER TABLE ONLY zonas
    ADD CONSTRAINT zonas_pkey PRIMARY KEY (cod_zona);

% for planta in plantas:
CREATE INDEX gist_${planta} ON ${planta} USING gist (geometria);

% endfor

CREATE INDEX todasestancias_btree ON todasestancias USING btree (codigo);

CREATE RULE actualiza_becarios AS ON UPDATE TO becarios WHERE (((((new.nif)::text <> (old.nif)::text) OR ((new.codigo)::text <> (old.codigo)::text)) OR ((new.cod_depto_centro_subunidad)::text <> (old.cod_depto_centro_subunidad)::text)) OR (((new.cod_puesto)::text <> (old.cod_puesto)::text) AND ((new.codigo)::text IN (SELECT todasestancias.codigo FROM todasestancias)))) DO UPDATE todaspersonas SET nif = new.nif, codigo = new.codigo, cod_puesto = new.cod_puesto, cod_depto = new.cod_depto_centro_subunidad, usuario = "current_user"(), fecha = ('now'::text)::date WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = (old.cod_puesto)::text)) AND ((todaspersonas.cod_depto)::text = (old.cod_depto_centro_subunidad)::text));

CREATE RULE actualiza_dpto_docente AS ON UPDATE TO departamentos WHERE ((((new.cod_dpto)::text <> (old.cod_dpto)::text) OR ((new.txt_dpto)::text <> (old.txt_dpto)::text)) OR ((new.cod_centro)::text <> (old.cod_centro)::text)) DO UPDATE departamentossigua SET cod_dpto_sigua = new.cod_dpto, txt_dpto_sigua = new.txt_dpto, cod_centro = new.cod_centro WHERE ((((departamentossigua.cod_dpto_sigua)::text = (old.cod_dpto)::text) AND ((departamentossigua.txt_dpto_sigua)::text = (old.txt_dpto)::text)) AND ((departamentossigua.cod_centro)::text = (old.cod_centro)::text));

CREATE RULE actualiza_personalexternos AS ON UPDATE TO personalexternos WHERE (((((new.nif)::text <> (old.nif)::text) OR ((new.codigo)::text <> (old.codigo)::text)) OR ((new.cod_dpto_sigua)::text <> (old.cod_dpto_sigua)::text)) OR ((new.cod_puesto)::text <> (old.cod_puesto)::text)) DO UPDATE todaspersonas SET nif = new.nif, codigo = new.codigo, cod_puesto = new.cod_puesto, cod_depto = new.cod_dpto_sigua, usuario = "current_user"(), fecha = ('now'::text)::date WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = (old.cod_puesto)::text)) AND ((todaspersonas.cod_depto)::text = (old.cod_dpto_sigua)::text));

CREATE RULE actualiza_personalpas AS ON UPDATE TO personalpas WHERE ((((((new.nif)::text <> (old.nif)::text) OR ((new.codigo)::text <> (old.codigo)::text)) OR ((new.cod_unidad)::text <> (old.cod_unidad)::text)) OR ((new.cod_sub)::text <> (old.cod_sub)::text)) OR ((new.cod_puesto)::text <> (old.cod_puesto)::text)) DO UPDATE todaspersonas SET nif = new.nif, codigo = new.codigo, cod_puesto = new.cod_puesto, cod_depto = new.cod_unidad, usuario = "current_user"(), fecha = ('now'::text)::date WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = (old.cod_puesto)::text)) AND ((todaspersonas.cod_depto)::text = (old.cod_unidad)::text));

CREATE RULE actualiza_personalpdi AS ON UPDATE TO personalpdi WHERE (((((new.nif)::text <> (old.nif)::text) OR ((new.codigo)::text <> (old.codigo)::text)) OR ((new.cod_depto)::text <> (old.cod_depto)::text)) OR ((new.cod_puesto)::text <> (old.cod_puesto)::text)) DO UPDATE todaspersonas SET nif = new.nif, codigo = new.codigo, cod_puesto = new.cod_puesto, cod_depto = new.cod_depto, usuario = "current_user"(), fecha = ('now'::text)::date WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = (old.cod_puesto)::text)) AND ((todaspersonas.cod_depto)::text = (old.cod_depto)::text));

CREATE RULE actualiza_personalpdi_cargos AS ON UPDATE TO personalpdi_cargos WHERE ((((new.nif)::text <> (old.nif)::text) OR ((new.codigo)::text <> (old.codigo)::text)) OR ((new.cod_cargo)::text <> (old.cod_cargo)::text)) DO UPDATE todaspersonas SET nif = new.nif, codigo = new.codigo, cod_puesto = 'CARGO'::character varying, cod_depto = 'CARGO'::character varying, usuario = "current_user"(), fecha = ('now'::text)::date WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = 'CARGO'::text)) AND ((todaspersonas.cod_depto)::text = 'CARGO'::text));

% for planta in plantas:
CREATE RULE actualiza_${planta} AS ON UPDATE TO ${planta} DO UPDATE todasestancias SET codigo = new.codigo, coddpto = new.coddpto, actividad = new.actividad, geometria = new.geometria, usuario = "current_user"(), fecha = ('now'::text)::date, denominaci = new.denominaci, observacio = new.observacio WHERE (((todasestancias.codigo)::text = (old.codigo)::text) AND (todasestancias.geometria = old.geometria));

% endfor

CREATE RULE actualiza_unidades AS ON UPDATE TO unidades WHERE ((((new.cod_unidad)::text <> (old.cod_unidad)::text) OR ((new.txt_unidad)::text <> (old.txt_unidad)::text)) OR ((new.cod_centro)::text <> (old.cod_centro)::text)) DO UPDATE departamentossigua SET cod_dpto_sigua = new.cod_unidad, txt_dpto_sigua = new.txt_unidad, cod_centro = new.cod_centro WHERE (((departamentossigua.cod_dpto_sigua)::text = (old.cod_unidad)::text) AND ((departamentossigua.txt_dpto_sigua)::text = (old.txt_unidad)::text));

CREATE RULE borra_becarios AS ON DELETE TO becarios DO DELETE FROM todaspersonas WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = (old.cod_puesto)::text)) AND ((todaspersonas.cod_depto)::text = (old.cod_depto_centro_subunidad)::text));

CREATE RULE borra_dpto_docente AS ON DELETE TO departamentos DO DELETE FROM departamentossigua WHERE ((departamentossigua.cod_dpto_sigua)::text = (old.cod_dpto)::text);

CREATE RULE borra_personalexternos AS ON DELETE TO personalexternos DO DELETE FROM todaspersonas WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = (old.cod_puesto)::text)) AND ((todaspersonas.cod_depto)::text = (old.cod_dpto_sigua)::text));

CREATE RULE borra_personalpas AS ON DELETE TO personalpas DO DELETE FROM todaspersonas WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = (old.cod_puesto)::text)) AND ((todaspersonas.cod_depto)::text = (old.cod_unidad)::text));

CREATE RULE borra_personalpdi AS ON DELETE TO personalpdi DO DELETE FROM todaspersonas WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = (old.cod_puesto)::text)) AND ((todaspersonas.cod_depto)::text = (old.cod_depto)::text));

CREATE RULE borra_personalpdi_cargos AS ON DELETE TO personalpdi_cargos DO DELETE FROM todaspersonas WHERE (((((todaspersonas.nif)::text = (old.nif)::text) AND ((todaspersonas.codigo)::text = (old.codigo)::text)) AND ((todaspersonas.cod_puesto)::text = 'CARGO'::text)) AND ((todaspersonas.cod_depto)::text = 'CARGO'::text));

% for planta in plantas:
CREATE RULE borra_${planta} AS ON DELETE TO ${planta} DO DELETE FROM todasestancias WHERE (((todasestancias.codigo)::text = (old.codigo)::text) AND (todasestancias.geometria = old.geometria));

% endfor

CREATE RULE borra_unidades AS ON DELETE TO unidades DO DELETE FROM departamentossigua WHERE ((departamentossigua.cod_dpto_sigua)::text = (old.cod_unidad)::text);

CREATE RULE inserta_becarios AS ON INSERT TO becarios DO INSERT INTO todaspersonas (nif, codigo, cod_puesto, cod_depto, usuario, fecha) VALUES (new.nif, new.codigo, new.cod_puesto, new.cod_depto_centro_subunidad, "current_user"(), ('now'::text)::date);

CREATE RULE inserta_dpto_docente AS ON INSERT TO departamentos WHERE (NOT ((new.cod_dpto)::text IN (SELECT departamentossigua.cod_dpto_sigua FROM departamentossigua))) DO INSERT INTO departamentossigua (cod_dpto_sigua, txt_dpto_sigua, cod_centro) VALUES (new.cod_dpto, new.txt_dpto, new.cod_centro);

CREATE RULE inserta_personalpas AS ON INSERT TO personalpas DO INSERT INTO todaspersonas (nif, codigo, cod_puesto, cod_depto, usuario, fecha) VALUES (new.nif, new.codigo, new.cod_puesto, new.cod_unidad, "current_user"(), ('now'::text)::date);

CREATE RULE inserta_personalpdi AS ON INSERT TO personalpdi DO INSERT INTO todaspersonas (nif, codigo, cod_puesto, cod_depto, usuario, fecha) VALUES (new.nif, new.codigo, new.cod_puesto, new.cod_depto, "current_user"(), ('now'::text)::date);

CREATE RULE inserta_personalpdi_cargos AS ON INSERT TO personalpdi_cargos DO INSERT INTO todaspersonas (nif, codigo, cod_puesto, cod_depto, usuario, fecha) VALUES (new.nif, new.codigo, 'CARGO'::character varying, 'CARGO'::character varying, "current_user"(), ('now'::text)::date);

% for planta in plantas:
CREATE RULE inserta_${planta} AS ON INSERT TO ${planta} DO INSERT INTO todasestancias (codigo, coddpto, actividad, usuario, fecha, geometria, denominaci, observacio) VALUES (new.codigo, new.coddpto, new.actividad, "current_user"(), ('now'::text)::date, new.geometria, new.denominaci, new.observacio);

% endfor

CREATE RULE inserta_unidades AS ON INSERT TO unidades WHERE (NOT ((new.cod_unidad)::text IN (SELECT departamentossigua.cod_dpto_sigua FROM departamentossigua))) DO INSERT INTO departamentossigua (cod_dpto_sigua, txt_dpto_sigua, cod_centro) VALUES (new.cod_unidad, new.txt_unidad, '1B00'::character varying);

% for planta in plantas:
CREATE TRIGGER borraestanciapers BEFORE DELETE ON ${planta} FOR EACH ROW EXECUTE PROCEDURE comprueba_personal_estancia();

% endfor

CREATE TRIGGER comprueba_actividad BEFORE INSERT OR UPDATE ON personalpas FOR EACH ROW EXECUTE PROCEDURE comprueba_actividad();

CREATE TRIGGER comprueba_actividad BEFORE INSERT OR UPDATE ON personalpdi FOR EACH ROW EXECUTE PROCEDURE comprueba_actividad();

CREATE TRIGGER comprueba_actividad BEFORE INSERT OR UPDATE ON personalpdi_cargos FOR EACH ROW EXECUTE PROCEDURE comprueba_actividad();

CREATE TRIGGER comprueba_actividad BEFORE INSERT OR UPDATE ON personalpas_cargos FOR EACH ROW EXECUTE PROCEDURE comprueba_actividad();

CREATE TRIGGER comprueba_actividad BEFORE INSERT OR UPDATE ON becarios FOR EACH ROW EXECUTE PROCEDURE comprueba_actividad();

CREATE TRIGGER comprueba_actividad BEFORE INSERT OR UPDATE ON personalexternos FOR EACH ROW EXECUTE PROCEDURE comprueba_actividad();

CREATE TRIGGER comprueba_estancia BEFORE INSERT OR UPDATE ON becarios FOR EACH ROW EXECUTE PROCEDURE comprueba_estancia();

CREATE TRIGGER comprueba_estancia BEFORE INSERT OR UPDATE ON personalpas FOR EACH ROW EXECUTE PROCEDURE comprueba_estancia();

CREATE TRIGGER comprueba_estancia BEFORE INSERT OR UPDATE ON personalpdi_cargos FOR EACH ROW EXECUTE PROCEDURE comprueba_estancia();

CREATE TRIGGER comprueba_estancia BEFORE INSERT OR UPDATE ON personalexternos FOR EACH ROW EXECUTE PROCEDURE comprueba_estancia();

CREATE TRIGGER comprueba_estancia BEFORE INSERT OR UPDATE ON personalpdi FOR EACH ROW EXECUTE PROCEDURE comprueba_estancia();

CREATE TRIGGER comprueba_superficie BEFORE INSERT OR UPDATE ON personalpas FOR EACH ROW EXECUTE PROCEDURE comprueba_superficie();

CREATE TRIGGER comprueba_superficie BEFORE INSERT OR UPDATE ON personalpdi FOR EACH ROW EXECUTE PROCEDURE comprueba_superficie();

CREATE TRIGGER comprueba_superficie BEFORE INSERT OR UPDATE ON personalpas_cargos FOR EACH ROW EXECUTE PROCEDURE comprueba_superficie();

CREATE TRIGGER comprueba_superficie BEFORE INSERT OR UPDATE ON personalpdi_cargos FOR EACH ROW EXECUTE PROCEDURE comprueba_superficie();

CREATE TRIGGER comprueba_superficie BEFORE INSERT OR UPDATE ON becarios FOR EACH ROW EXECUTE PROCEDURE comprueba_superficie();

% for planta in plantas:
CREATE TRIGGER comprueba_texto_estancia BEFORE INSERT OR UPDATE ON ${planta} FOR EACH ROW EXECUTE PROCEDURE comprueba_texto_estancia();

% endfor

CREATE TRIGGER inserta_personalexternos BEFORE INSERT ON personalexternos FOR EACH ROW EXECUTE PROCEDURE inserta_personalexternos();

ALTER TABLE ONLY edificios
    ADD CONSTRAINT "$1" FOREIGN KEY (cod_zona) REFERENCES zonas(cod_zona);

ALTER TABLE ONLY personalpdi_cargos
    ADD CONSTRAINT "$1" FOREIGN KEY (cod_cargo) REFERENCES cargos(cod_cargo);

ALTER TABLE ONLY personalpas_cargos
    ADD CONSTRAINT "$1" FOREIGN KEY (cod_cargo) REFERENCES cargos(cod_cargo);

ALTER TABLE ONLY becarios
    ADD CONSTRAINT "$1" FOREIGN KEY (cod_puesto) REFERENCES puestos(cod_puesto);

ALTER TABLE ONLY todasestancias
    ADD CONSTRAINT "$1" FOREIGN KEY (coddpto) REFERENCES departamentossigua(cod_dpto_sigua);

ALTER TABLE ONLY departamentossigua
    ADD CONSTRAINT "$1" FOREIGN KEY (cod_centro) REFERENCES centros(cod_centro);

ALTER TABLE ONLY personalpdi
    ADD CONSTRAINT "$1" FOREIGN KEY (cod_puesto) REFERENCES puestos(cod_puesto);

ALTER TABLE ONLY personalexternos
    ADD CONSTRAINT "$1" FOREIGN KEY (cod_dpto_sigua) REFERENCES departamentossigua(cod_dpto_sigua);

ALTER TABLE ONLY personalpas
    ADD CONSTRAINT "$1" FOREIGN KEY (cod_unidad) REFERENCES departamentossigua(cod_dpto_sigua);

ALTER TABLE ONLY personalpdi_cargos
    ADD CONSTRAINT "$2" FOREIGN KEY (nif) REFERENCES personal(nif);

ALTER TABLE ONLY personalpas_cargos
    ADD CONSTRAINT "$2" FOREIGN KEY (nif) REFERENCES personal(nif);

ALTER TABLE ONLY todasestancias
    ADD CONSTRAINT "$2" FOREIGN KEY (actividad) REFERENCES actividades(codactividad);

ALTER TABLE ONLY personalpas
    ADD CONSTRAINT "$2" FOREIGN KEY (cod_sub) REFERENCES subunidades(cod_sub);

ALTER TABLE ONLY personalpdi
    ADD CONSTRAINT "$2" FOREIGN KEY (cod_centro) REFERENCES centros(cod_centro);

ALTER TABLE ONLY personalexternos
    ADD CONSTRAINT "$2" FOREIGN KEY (cod_puesto) REFERENCES puestos(cod_puesto);

% for planta in plantas:
ALTER TABLE ONLY ${planta}
    ADD CONSTRAINT "$3" FOREIGN KEY (actividad) REFERENCES actividades(codactividad);

% endfor

ALTER TABLE ONLY personalpas
    ADD CONSTRAINT "$3" FOREIGN KEY (cod_centro) REFERENCES centros(cod_centro);

ALTER TABLE ONLY personalpdi
    ADD CONSTRAINT "$3" FOREIGN KEY (nif) REFERENCES personal(nif);

ALTER TABLE ONLY personalpas
    ADD CONSTRAINT "$4" FOREIGN KEY (cod_puesto) REFERENCES puestos(cod_puesto);

% for planta in plantas:
ALTER TABLE ONLY ${planta}
    ADD CONSTRAINT "$4" FOREIGN KEY (coddpto) REFERENCES departamentossigua(cod_dpto_sigua);

% endfor

ALTER TABLE ONLY personalpdi
    ADD CONSTRAINT "$4" FOREIGN KEY (cod_depto) REFERENCES departamentos(cod_dpto);

ALTER TABLE ONLY personalpas
    ADD CONSTRAINT "$5" FOREIGN KEY (nif) REFERENCES personal(nif);

ALTER TABLE ONLY departamentos
    ADD CONSTRAINT "FK_centro_dpto" FOREIGN KEY (cod_centro) REFERENCES centros(cod_centro);

ALTER TABLE ONLY cargos_dpto
    ADD CONSTRAINT codcargo_codcargo FOREIGN KEY (cod_cargo) REFERENCES cargos(cod_cargo) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY cargos_dpto
    ADD CONSTRAINT dptocargo FOREIGN KEY (coddpto) REFERENCES departamentossigua(cod_dpto_sigua) ON UPDATE RESTRICT ON DELETE RESTRICT;

