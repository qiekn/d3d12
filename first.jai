#import "Basic";
#import "Compiler";

build :: () {
    w := compiler_create_workspace("Jailor");
    if !w {
        print("The world is not ready for Jai!\n");
        return;
    }

    print("Hello, Jailor!\n");

    options := get_build_options(w);
    options.output_executable_name = "game";
    set_build_options(options, w);

    add_build_file("./src/game.jai", w);
    set_build_options_dc(.{do_output=false});
}

#run build();
